-- Ritmo — banco completo no projeto enamed-engine (ConsultaIA), isolado por prefixo "ritmo_".
-- Não altera nenhuma tabela ou função existente. Pode ser rodado mais de uma vez.

-- 1) Estado do app: um documento por conta, com número de revisão para sincronizar aparelhos
create table if not exists public.ritmo_estado (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  dados         jsonb       not null default '{}'::jsonb,
  rev           integer     not null default 1,
  versao_app    text,
  atualizado_em timestamptz not null default now(),
  criado_em     timestamptz not null default now(),
  constraint ritmo_estado_tamanho_max check (pg_column_size(dados) < 2097152)
);

create or replace function public.ritmo_tocar_estado()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.atualizado_em := now();
  if tg_op = 'UPDATE' then new.rev := old.rev + 1; else new.rev := 1; end if;
  return new;
end $$;
drop trigger if exists ritmo_trg_estado on public.ritmo_estado;
create trigger ritmo_trg_estado before insert or update on public.ritmo_estado
  for each row execute function public.ritmo_tocar_estado();

-- 2) Planos, assinaturas, pagamentos e controle de teste grátis
create table if not exists public.ritmo_planos (
  id text primary key, nome text not null,
  valor numeric(10,2) not null check (valor > 0), dias int not null check (dias > 0),
  ordem int not null default 0, ativo boolean not null default true
);
insert into public.ritmo_planos (id,nome,valor,dias,ordem) values
  ('mensal','Mensal',9.90,30,1), ('semestral','6 meses',49.90,183,2), ('anual','Anual',89.90,365,3)
on conflict (id) do nothing;

create table if not exists public.ritmo_assinaturas (
  user_id uuid primary key references auth.users(id) on delete cascade,
  trial_ate timestamptz not null default (now() + interval '7 days'),
  valido_ate timestamptz, plano text references public.ritmo_planos(id),
  criado_em timestamptz not null default now(), atualizado_em timestamptz not null default now()
);

create table if not exists public.ritmo_pagamentos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  plano text not null references public.ritmo_planos(id),
  valor numeric(10,2) not null, dias int not null,
  status text not null default 'pendente',   -- pendente | aprovado | recusado | estornado
  mp_preference text, mp_payment_id text unique, metodo text,
  criado_em timestamptz not null default now(), pago_em timestamptz
);
create index if not exists ritmo_pagamentos_user_idx on public.ritmo_pagamentos(user_id, criado_em desc);

-- Um teste grátis por e-mail (ignora pontos e "+algo" do Gmail e sobrevive a excluir/recriar a conta)
create table if not exists public.ritmo_trials (
  email_norm text primary key, user_id uuid, criado_em timestamptz not null default now()
);

alter table public.ritmo_estado      enable row level security;
alter table public.ritmo_planos      enable row level security;
alter table public.ritmo_assinaturas enable row level security;
alter table public.ritmo_pagamentos  enable row level security;
alter table public.ritmo_trials      enable row level security;

-- Permissões: tira tudo e devolve só o necessário
revoke all on public.ritmo_estado, public.ritmo_planos, public.ritmo_assinaturas, public.ritmo_pagamentos, public.ritmo_trials from anon, authenticated;
grant select, insert, update, delete on public.ritmo_estado to authenticated;
grant select on public.ritmo_planos to anon, authenticated;
grant select on public.ritmo_assinaturas, public.ritmo_pagamentos to authenticated;
grant all on public.ritmo_estado, public.ritmo_planos, public.ritmo_assinaturas, public.ritmo_pagamentos, public.ritmo_trials to service_role;

-- A minha conta está liberada? (teste grátis ou plano em dia)
create or replace function public.ritmo_eu_ativo()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.ritmo_assinaturas a
    where a.user_id = (select auth.uid()) and greatest(a.trial_ate, coalesce(a.valido_ate, a.trial_ate)) > now());
$$;

drop policy if exists ritmo_planos_leitura on public.ritmo_planos;
create policy ritmo_planos_leitura on public.ritmo_planos for select to anon, authenticated using (ativo);
drop policy if exists ritmo_assinatura_propria on public.ritmo_assinaturas;
create policy ritmo_assinatura_propria on public.ritmo_assinaturas for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists ritmo_pagamentos_proprios on public.ritmo_pagamentos;
create policy ritmo_pagamentos_proprios on public.ritmo_pagamentos for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists ritmo_estado_select on public.ritmo_estado;
create policy ritmo_estado_select on public.ritmo_estado for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists ritmo_estado_delete on public.ritmo_estado;
create policy ritmo_estado_delete on public.ritmo_estado for delete to authenticated using ((select auth.uid()) = user_id);
-- gravar na nuvem só com a conta ativa; ler continua liberado (a pessoa nunca perde os dados)
drop policy if exists ritmo_estado_insert on public.ritmo_estado;
create policy ritmo_estado_insert on public.ritmo_estado for insert to authenticated
  with check ((select auth.uid()) = user_id and (select public.ritmo_eu_ativo()));
drop policy if exists ritmo_estado_update on public.ritmo_estado;
create policy ritmo_estado_update on public.ritmo_estado for update to authenticated
  using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id and (select public.ritmo_eu_ativo()));

-- Situação da minha assinatura; na primeira chamada abre o teste de 7 dias (um por e-mail)
create or replace function public.ritmo_minha_assinatura()
returns json language plpgsql security definer set search_path = '' as $$
declare a public.ritmo_assinaturas; fim timestamptz; em text; loc text; dom text; n int;
begin
  if auth.uid() is null then raise exception 'sem sessão'; end if;
  select * into a from public.ritmo_assinaturas where user_id = auth.uid();
  if not found then
    select lower(trim(email)) into em from auth.users where id = auth.uid();
    loc := split_part(split_part(coalesce(em,''),'@',1),'+',1); dom := split_part(coalesce(em,''),'@',2);
    if dom in ('gmail.com','googlemail.com') then loc := replace(loc,'.',''); dom := 'gmail.com'; end if;
    insert into public.ritmo_trials(email_norm,user_id) values (coalesce(nullif(loc||'@'||dom,'@'), auth.uid()::text), auth.uid())
      on conflict (email_norm) do nothing;
    get diagnostics n = row_count;
    insert into public.ritmo_assinaturas(user_id, trial_ate)
      values (auth.uid(), case when n = 1 then now() + interval '7 days' else now() end)
      on conflict (user_id) do nothing;
    select * into a from public.ritmo_assinaturas where user_id = auth.uid();
  end if;
  fim := greatest(a.trial_ate, coalesce(a.valido_ate, a.trial_ate));
  return json_build_object('ativo', fim > now(),
    'fase', case when a.valido_ate is not null and a.valido_ate > now() then 'pago'
                 when a.trial_ate > now() then 'teste' else 'vencido' end,
    'fim', fim, 'plano', a.plano, 'trial_ate', a.trial_ate, 'valido_ate', a.valido_ate, 'agora', now());
end $$;

-- Credita pagamento aprovado (não credita duas vezes). Só a Edge Function chama.
create or replace function public.ritmo_creditar_pagamento(p_ref uuid, p_mp_id text, p_metodo text)
returns json language plpgsql security definer set search_path = '' as $$
declare pg public.ritmo_pagamentos; novo timestamptz;
begin
  update public.ritmo_pagamentos set status='aprovado', mp_payment_id=p_mp_id, metodo=p_metodo, pago_em=now()
   where id = p_ref and status in ('pendente','recusado') returning * into pg;
  if not found then return json_build_object('creditado', false); end if;
  insert into public.ritmo_assinaturas(user_id, trial_ate) values (pg.user_id, now()) on conflict (user_id) do nothing;
  update public.ritmo_assinaturas
     set valido_ate = greatest(now(), coalesce(valido_ate, now()), trial_ate) + make_interval(days => pg.dias),
         plano = pg.plano, atualizado_em = now()
   where user_id = pg.user_id returning valido_ate into novo;
  return json_build_object('creditado', true, 'user_id', pg.user_id, 'valido_ate', novo);
end $$;

-- Estorno ou chargeback: tira os dias daquele pagamento. Só a Edge Function chama.
create or replace function public.ritmo_estornar_pagamento(p_ref uuid)
returns json language plpgsql security definer set search_path = '' as $$
declare pg public.ritmo_pagamentos; novo timestamptz;
begin
  update public.ritmo_pagamentos set status='estornado' where id = p_ref and status = 'aprovado' returning * into pg;
  if not found then return json_build_object('estornado', false); end if;
  update public.ritmo_assinaturas set valido_ate = valido_ate - make_interval(days => pg.dias), atualizado_em = now()
   where user_id = pg.user_id returning valido_ate into novo;
  return json_build_object('estornado', true, 'user_id', pg.user_id, 'valido_ate', novo);
end $$;

revoke all on function public.ritmo_tocar_estado(), public.ritmo_eu_ativo(), public.ritmo_minha_assinatura(),
  public.ritmo_creditar_pagamento(uuid,text,text), public.ritmo_estornar_pagamento(uuid) from public, anon, authenticated;
grant execute on function public.ritmo_eu_ativo(), public.ritmo_minha_assinatura() to authenticated;
grant execute on function public.ritmo_creditar_pagamento(uuid,text,text), public.ritmo_estornar_pagamento(uuid) to service_role;

-- Consultas úteis para você:
-- select u.email, a.trial_ate, a.valido_ate, a.plano from public.ritmo_assinaturas a join auth.users u on u.id=a.user_id order by a.criado_em desc;
-- select count(*), sum(valor) from public.ritmo_pagamentos where status='aprovado';
notify pgrst, 'reload schema';
