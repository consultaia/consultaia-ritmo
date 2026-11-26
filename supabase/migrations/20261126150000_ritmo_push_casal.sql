-- Ritmo — avisos com o app fechado (push), plano Casal e limite de leitura de escala por foto.
-- Projeto enamed-engine. Só cria/atualiza objetos "ritmo_". Pode ser rodado mais de uma vez.

-- ============ Configuração interna (chaves do push e segredo do agendador) ============
create table if not exists public.ritmo_config (chave text primary key, valor text not null);
alter table public.ritmo_config enable row level security;
revoke all on public.ritmo_config from anon, authenticated;
grant all on public.ritmo_config to service_role;
insert into public.ritmo_config(chave,valor) values ('cron', gen_random_uuid()::text) on conflict do nothing;

-- ============ Push: aparelhos inscritos e horários a avisar ============
create table if not exists public.ritmo_push_subs (
  endpoint text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  criado_em timestamptz not null default now()
);
create index if not exists ritmo_push_subs_user_idx on public.ritmo_push_subs(user_id);

-- Só guarda QUANDO avisar; o texto do lembrete fica no aparelho.
create table if not exists public.ritmo_avisos (
  user_id uuid not null references auth.users(id) on delete cascade,
  rid text not null, quando timestamptz not null, rep text not null default '',
  primary key (user_id, rid)
);
create index if not exists ritmo_avisos_quando_idx on public.ritmo_avisos(quando);

alter table public.ritmo_push_subs enable row level security;
alter table public.ritmo_avisos    enable row level security;
revoke all on public.ritmo_push_subs, public.ritmo_avisos from anon, authenticated;
grant all on public.ritmo_push_subs, public.ritmo_avisos to service_role;

create or replace function public.ritmo_push_inscrever(p_endpoint text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'sem sessão'; end if;
  if p_endpoint is null or p_endpoint !~ '^https://' or length(p_endpoint) > 1000 then raise exception 'endpoint inválido'; end if;
  insert into public.ritmo_push_subs(endpoint,user_id) values (p_endpoint, auth.uid())
    on conflict (endpoint) do update set user_id = excluded.user_id;
  delete from public.ritmo_push_subs where user_id = auth.uid() and endpoint not in
    (select endpoint from public.ritmo_push_subs where user_id = auth.uid() order by criado_em desc limit 10);
end $$;

create or replace function public.ritmo_push_sair(p_endpoint text)
returns void language sql security definer set search_path = '' as $$
  delete from public.ritmo_push_subs where endpoint = p_endpoint and user_id = (select auth.uid());
$$;

-- O app manda a lista de horários pendentes: [{"id":"..","quando":"2026-11-27T11:00:00Z","rep":""}]
create or replace function public.ritmo_sync_avisos(p jsonb)
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if auth.uid() is null then raise exception 'sem sessão'; end if;
  delete from public.ritmo_avisos where user_id = auth.uid();
  insert into public.ritmo_avisos(user_id, rid, quando, rep)
    select auth.uid(), left(x.id,60), x.quando, case when x.rep in ('dia','semana','mes') then x.rep else '' end
    from jsonb_to_recordset(coalesce(p,'[]'::jsonb)) as x(id text, quando timestamptz, rep text)
    where x.id is not null and x.quando is not null and x.quando > now() - interval '1 minute' and x.quando < now() + interval '400 days'
    order by x.quando limit 300
  on conflict (user_id, rid) do nothing;
  get diagnostics n = row_count; return n;
end $$;

-- Pega os avisos vencidos, avança os repetidos, apaga os demais e devolve os aparelhos a acordar.
create or replace function public.ritmo_avisos_pegar()
returns setof text language sql security definer set search_path = '' as $$
  with due as (
    select user_id, rid, quando, rep from public.ritmo_avisos where quando <= now() for update skip locked
  ), del as (
    delete from public.ritmo_avisos a using due d where a.user_id = d.user_id and a.rid = d.rid and d.rep = '' returning 1
  ), upd as (
    update public.ritmo_avisos a set quando = case d.rep
        when 'dia'    then d.quando + make_interval(days => (floor(extract(epoch from now() - d.quando) / 86400)::int + 1))
        when 'semana' then d.quando + make_interval(days => 7 * (floor(extract(epoch from now() - d.quando) / 604800)::int + 1))
        else d.quando + make_interval(months => ((extract(year from age(now(), d.quando)) * 12 + extract(month from age(now(), d.quando)))::int + 1)) end
    from due d where a.user_id = d.user_id and a.rid = d.rid and d.rep <> '' returning 1
  )
  select distinct s.endpoint from due d join public.ritmo_push_subs s on s.user_id = d.user_id
   where d.quando > now() - interval '2 hours' and (select count(*) from del) >= 0 and (select count(*) from upd) >= 0;
$$;

-- Chamado a cada minuto pelo agendador: só acorda a função de envio se houver aviso vencido.
create or replace function public.ritmo_cron_push()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.ritmo_avisos where quando <= now()) then
    perform net.http_post(
      url := 'https://jtkkqmqlydqenxwnttyi.supabase.co/functions/v1/ritmo-push/enviar',
      body := '{}'::jsonb,
      headers := jsonb_build_object('Content-Type','application/json','x-ritmo-cron',(select valor from public.ritmo_config where chave = 'cron')));
  end if;
end $$;

-- ============ Escala por foto: limite diário por conta ============
create table if not exists public.ritmo_ia_uso (
  user_id uuid not null references auth.users(id) on delete cascade,
  dia date not null default current_date, n int not null default 0, primary key (user_id, dia)
);
alter table public.ritmo_ia_uso enable row level security;
revoke all on public.ritmo_ia_uso from anon, authenticated;
grant all on public.ritmo_ia_uso to service_role;

-- Conta +1 uso de hoje e devolve o total; a Edge Function recusa acima do limite.
create or replace function public.ritmo_ia_contar(p_user uuid)
returns int language sql security definer set search_path = '' as $$
  insert into public.ritmo_ia_uso(user_id, dia, n) values (p_user, current_date, 1)
    on conflict (user_id, dia) do update set n = public.ritmo_ia_uso.n + 1 returning n;
$$;

-- ============ Plano Casal ============
alter table public.ritmo_planos add column if not exists pessoas int not null default 1;
insert into public.ritmo_planos (id,nome,valor,dias,ordem,pessoas) values
  ('casal_mensal','Casal mensal',14.90,30,4,2), ('casal_anual','Casal anual',129.90,365,5,2)
on conflict (id) do nothing;

create table if not exists public.ritmo_convites (
  dono uuid primary key references auth.users(id) on delete cascade,
  email text not null unique, criado_em timestamptz not null default now()
);
alter table public.ritmo_convites enable row level security;
revoke all on public.ritmo_convites from anon, authenticated;
grant all on public.ritmo_convites to service_role;

-- Até quando a conta está coberta pelo plano Casal de outra pessoa (ou null)
create or replace function public.ritmo_coberto_ate(p_user uuid)
returns timestamptz language sql stable security definer set search_path = '' as $$
  select max(a.valido_ate) from public.ritmo_convites c
    join auth.users u on lower(trim(u.email)) = c.email and u.id = p_user
    join public.ritmo_assinaturas a on a.user_id = c.dono
   where a.plano like 'casal%' and a.valido_ate > now();
$$;

-- Dono do plano Casal define (ou remove, com e-mail vazio) quem divide o plano
create or replace function public.ritmo_convidar(p_email text)
returns json language plpgsql security definer set search_path = '' as $$
declare e text := lower(trim(coalesce(p_email,''))); meu text;
begin
  if auth.uid() is null then raise exception 'sem sessão'; end if;
  if e = '' then delete from public.ritmo_convites where dono = auth.uid(); return json_build_object('ok', true, 'parceiro', null); end if;
  if not exists (select 1 from public.ritmo_assinaturas where user_id = auth.uid() and plano like 'casal%' and valido_ate > now())
    then return json_build_object('ok', false, 'erro', 'O plano Casal não está ativo nesta conta.'); end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return json_build_object('ok', false, 'erro', 'E-mail inválido.'); end if;
  select lower(trim(email)) into meu from auth.users where id = auth.uid();
  if e = meu then return json_build_object('ok', false, 'erro', 'Use o e-mail da outra pessoa, não o seu.'); end if;
  if exists (select 1 from public.ritmo_convites where email = e and dono <> auth.uid())
    then return json_build_object('ok', false, 'erro', 'Esse e-mail já está em outro plano Casal.'); end if;
  insert into public.ritmo_convites(dono,email) values (auth.uid(), e) on conflict (dono) do update set email = excluded.email, criado_em = now();
  return json_build_object('ok', true, 'parceiro', e);
end $$;

create or replace function public.ritmo_eu_ativo()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.ritmo_assinaturas a
    where a.user_id = (select auth.uid()) and greatest(a.trial_ate, coalesce(a.valido_ate, a.trial_ate)) > now())
    or coalesce(public.ritmo_coberto_ate((select auth.uid())) > now(), false);
$$;

create or replace function public.ritmo_minha_assinatura()
returns json language plpgsql security definer set search_path = '' as $$
declare a public.ritmo_assinaturas; fim timestamptz; em text; loc text; dom text; n int; cob timestamptz; pago boolean; casal boolean;
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
  cob := public.ritmo_coberto_ate(auth.uid());
  pago := a.valido_ate is not null and a.valido_ate > now();
  casal := pago and a.plano like 'casal%';
  fim := greatest(a.trial_ate, coalesce(a.valido_ate, a.trial_ate), coalesce(cob, a.trial_ate));
  return json_build_object('ativo', fim > now(),
    'fase', case when pago or cob > now() then 'pago' when a.trial_ate > now() then 'teste' else 'vencido' end,
    'fim', fim, 'plano', case when not pago and cob > now() then 'casal' else a.plano end,
    'trial_ate', a.trial_ate, 'valido_ate', a.valido_ate, 'agora', now(),
    'casal', casal, 'convidado', (not pago and coalesce(cob > now(), false)),
    'parceiro', (select email from public.ritmo_convites where dono = auth.uid()));
end $$;

revoke all on function public.ritmo_push_inscrever(text), public.ritmo_push_sair(text), public.ritmo_sync_avisos(jsonb),
  public.ritmo_avisos_pegar(), public.ritmo_cron_push(), public.ritmo_ia_contar(uuid), public.ritmo_coberto_ate(uuid),
  public.ritmo_convidar(text), public.ritmo_eu_ativo(), public.ritmo_minha_assinatura() from public, anon, authenticated;
grant execute on function public.ritmo_push_inscrever(text), public.ritmo_push_sair(text), public.ritmo_sync_avisos(jsonb),
  public.ritmo_convidar(text), public.ritmo_eu_ativo(), public.ritmo_minha_assinatura() to authenticated;
grant execute on function public.ritmo_avisos_pegar(), public.ritmo_ia_contar(uuid), public.ritmo_coberto_ate(uuid) to service_role;

notify pgrst, 'reload schema';
