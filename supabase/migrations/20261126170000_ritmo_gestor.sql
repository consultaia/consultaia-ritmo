-- Ritmo — painel do gestor (métricas e cortesia). Só contas listadas em ritmo_admins acessam.
create table if not exists public.ritmo_admins (user_id uuid primary key references auth.users(id) on delete cascade);
alter table public.ritmo_admins enable row level security;
revoke all on public.ritmo_admins from anon, authenticated;
grant all on public.ritmo_admins to service_role;
-- dono do produto
insert into public.ritmo_admins(user_id) select id from auth.users where id = 'c14c38b7-a80f-4864-ab53-068fcdb8f449' on conflict do nothing;

create or replace function public.ritmo_eu_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.ritmo_admins where user_id = (select auth.uid()));
$$;

create or replace function public.ritmo_admin_metricas()
returns json language plpgsql stable security definer set search_path = '' as $$
declare r json;
begin
  if not public.ritmo_eu_admin() then raise exception 'acesso negado'; end if;
  with a as (
    select s.user_id, u.email, s.criado_em, s.trial_ate, s.valido_ate, s.plano,
           (s.valido_ate is not null and s.valido_ate > now()) as pago,
           coalesce(public.ritmo_coberto_ate(s.user_id) > now(), false) as cob
      from public.ritmo_assinaturas s join auth.users u on u.id = s.user_id
  ), f as (
    select a.*, case when pago then 'pago' when cob then 'convidado' when trial_ate > now() then 'teste' else 'vencido' end as fase from a
  ), pg as (
    select p.*, u.email from public.ritmo_pagamentos p join auth.users u on u.id = p.user_id
  )
  select json_build_object(
    'agora', now(),
    'contas', (select count(*) from f),
    'teste', (select count(*) from f where fase = 'teste'),
    'pagantes', (select count(*) from f where fase = 'pago'),
    'convidados', (select count(*) from f where fase = 'convidado'),
    'vencidos', (select count(*) from f where fase = 'vencido'),
    'novos7', (select count(*) from f where criado_em > now() - interval '7 days'),
    'novos30', (select count(*) from f where criado_em > now() - interval '30 days'),
    'ativos7', (select count(*) from public.ritmo_estado where atualizado_em > now() - interval '7 days'),
    'receita_total', coalesce((select sum(valor) from pg where status = 'aprovado'), 0),
    'receita_30d', coalesce((select sum(valor) from pg where status = 'aprovado' and pago_em > now() - interval '30 days'), 0),
    'vendas', (select count(*) from pg where status = 'aprovado'),
    'estornos', (select count(*) from pg where status = 'estornado'),
    'pendentes', (select count(*) from pg where status = 'pendente' and criado_em > now() - interval '2 days'),
    'mrr', coalesce((select round(sum(pl.valor / (pl.dias / 30.4)), 2) from f join public.ritmo_planos pl on pl.id = f.plano where f.fase = 'pago'), 0),
    'conversao', (select case when count(*) = 0 then null else round(100.0 * count(*) filter (where exists
                    (select 1 from pg where pg.user_id = f.user_id and pg.status = 'aprovado')) / count(*), 1) end from f),
    'push', (select count(distinct user_id) from public.ritmo_push_subs),
    'fotos7', coalesce((select sum(n) from public.ritmo_ia_uso where dia > current_date - 7), 0),
    'por_plano', coalesce((select json_agg(json_build_object('plano', plano, 'n', n, 'valor', v) order by v desc)
                    from (select plano, count(*) n, sum(valor) v from pg where status = 'aprovado' group by plano) x), '[]'::json),
    'por_dia', (select json_agg(json_build_object('dia', d::date, 'n', (select count(*) from f where f.criado_em::date = d::date)) order by d)
                    from generate_series(current_date - 13, current_date, interval '1 day') d),
    'recentes', coalesce((select json_agg(x) from (select email, criado_em, fase, plano,
                    greatest(trial_ate, coalesce(valido_ate, trial_ate)) as fim from f order by criado_em desc limit 25) x), '[]'::json),
    'pagamentos', coalesce((select json_agg(x) from (select email, plano, valor, status, metodo, criado_em from pg order by criado_em desc limit 15) x), '[]'::json)
  ) into r;
  return r;
end $$;

-- Dá dias grátis a uma conta (parceria, brinde, suporte)
create or replace function public.ritmo_admin_cortesia(p_email text, p_dias int)
returns json language plpgsql security definer set search_path = '' as $$
declare uid uuid; novo timestamptz;
begin
  if not public.ritmo_eu_admin() then raise exception 'acesso negado'; end if;
  if p_dias is null or p_dias < 1 or p_dias > 730 then return json_build_object('ok', false, 'erro', 'Dias entre 1 e 730.'); end if;
  select id into uid from auth.users where lower(trim(email)) = lower(trim(p_email)) limit 1;
  if uid is null then return json_build_object('ok', false, 'erro', 'Esse e-mail ainda não tem conta. Peça para a pessoa criar a conta primeiro.'); end if;
  insert into public.ritmo_assinaturas(user_id, trial_ate) values (uid, now()) on conflict (user_id) do nothing;
  update public.ritmo_assinaturas set valido_ate = greatest(now(), coalesce(valido_ate, now())) + make_interval(days => p_dias), atualizado_em = now()
   where user_id = uid returning valido_ate into novo;
  return json_build_object('ok', true, 'valido_ate', novo);
end $$;

revoke all on function public.ritmo_eu_admin(), public.ritmo_admin_metricas(), public.ritmo_admin_cortesia(text,int) from public, anon, authenticated;
grant execute on function public.ritmo_eu_admin(), public.ritmo_admin_metricas(), public.ritmo_admin_cortesia(text,int) to authenticated;
notify pgrst, 'reload schema';
