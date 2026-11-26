-- Ritmo — assinaturas (multitenant: cada conta é um cliente independente).
-- Rodar uma vez no SQL Editor do dri-imoveis, depois da migration 20261126040000_ritmo_schema.sql.

-- Planos (preço lido pelo servidor; o app nunca define valor)
create table if not exists ritmo.planos (
  id     text primary key,
  nome   text not null,
  valor  numeric(10,2) not null check (valor > 0),
  dias   int not null check (dias > 0),
  ordem  int not null default 0,
  ativo  boolean not null default true
);
insert into ritmo.planos (id,nome,valor,dias,ordem) values
  ('mensal','Mensal',9.90,30,1),
  ('semestral','6 meses',49.90,183,2),
  ('anual','Anual',89.90,365,3)
on conflict (id) do nothing;

-- Situação da assinatura de cada conta
create table if not exists ritmo.assinaturas (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  trial_ate     timestamptz not null default (now() + interval '7 days'),
  valido_ate    timestamptz,
  plano         text references ritmo.planos(id),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

-- Pagamentos (Mercado Pago Checkout Pro: Pix ou cartão)
create table if not exists ritmo.pagamentos (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users(id) on delete cascade,
  plano          text not null references ritmo.planos(id),
  valor          numeric(10,2) not null,
  dias           int not null,
  status         text not null default 'pendente',   -- pendente | aprovado | recusado
  mp_preference  text,
  mp_payment_id  text unique,
  metodo         text,
  criado_em      timestamptz not null default now(),
  pago_em        timestamptz
);
create index if not exists pagamentos_user_idx on ritmo.pagamentos(user_id, criado_em desc);

alter table ritmo.planos      enable row level security;
alter table ritmo.assinaturas enable row level security;
alter table ritmo.pagamentos  enable row level security;

drop policy if exists "ritmo_planos_leitura" on ritmo.planos;
create policy "ritmo_planos_leitura" on ritmo.planos for select to anon, authenticated using (ativo);

drop policy if exists "ritmo_assinatura_propria" on ritmo.assinaturas;
create policy "ritmo_assinatura_propria" on ritmo.assinaturas for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "ritmo_pagamentos_proprios" on ritmo.pagamentos;
create policy "ritmo_pagamentos_proprios" on ritmo.pagamentos for select to authenticated using ((select auth.uid()) = user_id);

-- O app só lê; quem grava assinatura e pagamento é a Edge Function (service role).
grant usage on schema ritmo to anon, authenticated;
grant select on ritmo.planos to anon, authenticated;
grant select on ritmo.assinaturas, ritmo.pagamentos to authenticated;
revoke insert, update, delete on ritmo.assinaturas, ritmo.pagamentos, ritmo.planos from anon, authenticated;

-- Conta está liberada? (teste grátis ou plano pago em dia)
create or replace function ritmo.ativo(uid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from ritmo.assinaturas a
    where a.user_id = uid and greatest(a.trial_ate, coalesce(a.valido_ate, a.trial_ate)) > now()
  );
$$;
revoke all on function ritmo.ativo(uuid) from public;
grant execute on function ritmo.ativo(uuid) to authenticated;

-- Situação da minha conta; na primeira chamada cria o teste grátis de 7 dias.
create or replace function ritmo.minha_assinatura()
returns json language plpgsql security definer set search_path = '' as $$
declare a ritmo.assinaturas; fim timestamptz;
begin
  if auth.uid() is null then raise exception 'sem sessão'; end if;
  insert into ritmo.assinaturas(user_id) values (auth.uid()) on conflict (user_id) do nothing;
  select * into a from ritmo.assinaturas where user_id = auth.uid();
  fim := greatest(a.trial_ate, coalesce(a.valido_ate, a.trial_ate));
  return json_build_object(
    'ativo', fim > now(),
    'fase', case when a.valido_ate is not null and a.valido_ate > now() then 'pago'
                 when a.trial_ate > now() then 'teste' else 'vencido' end,
    'fim', fim, 'plano', a.plano, 'trial_ate', a.trial_ate, 'valido_ate', a.valido_ate);
end $$;
revoke all on function ritmo.minha_assinatura() from public;
grant execute on function ritmo.minha_assinatura() to authenticated;

-- Credita um pagamento aprovado (idempotente). Chamada só pela Edge Function.
create or replace function ritmo.creditar_pagamento(p_ref uuid, p_mp_id text, p_metodo text)
returns json language plpgsql security definer set search_path = '' as $$
declare pg ritmo.pagamentos; novo timestamptz;
begin
  update ritmo.pagamentos set status='aprovado', mp_payment_id=p_mp_id, metodo=p_metodo, pago_em=now()
   where id = p_ref and status <> 'aprovado'
   returning * into pg;
  if not found then return json_build_object('creditado', false); end if;
  insert into ritmo.assinaturas(user_id) values (pg.user_id) on conflict (user_id) do nothing;
  update ritmo.assinaturas
     set valido_ate = greatest(now(), coalesce(valido_ate, now()), trial_ate) + make_interval(days => pg.dias),
         plano = pg.plano, atualizado_em = now()
   where user_id = pg.user_id
   returning valido_ate into novo;
  return json_build_object('creditado', true, 'user_id', pg.user_id, 'valido_ate', novo);
end $$;
revoke all on function ritmo.creditar_pagamento(uuid, text, text) from public, anon, authenticated;
grant execute on function ritmo.creditar_pagamento(uuid, text, text) to service_role;

grant usage on schema ritmo to service_role;
grant all on all tables in schema ritmo to service_role;

-- Sincronização só grava com a conta ativa; leitura segue liberada (a pessoa nunca perde os dados).
drop policy if exists "ritmo_estado_insert_proprio" on ritmo.estado;
create policy "ritmo_estado_insert_proprio" on ritmo.estado
  for insert to authenticated with check ((select auth.uid()) = user_id and ritmo.ativo((select auth.uid())));

drop policy if exists "ritmo_estado_update_proprio" on ritmo.estado;
create policy "ritmo_estado_update_proprio" on ritmo.estado
  for update to authenticated using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id and ritmo.ativo((select auth.uid())));

-- Painel rápido para você (rode no SQL Editor quando quiser):
-- select u.email, a.trial_ate, a.valido_ate, a.plano from ritmo.assinaturas a join auth.users u on u.id=a.user_id order by a.criado_em desc;
-- select sum(valor), count(*) from ritmo.pagamentos where status='aprovado';

notify pgrst, 'reload schema';
