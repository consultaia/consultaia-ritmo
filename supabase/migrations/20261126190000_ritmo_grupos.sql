-- Ritmo — agendas compartilhadas por código. Cada pessoa publica só o que escolheu compartilhar.
create table if not exists public.ritmo_grupos (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique,
  dono uuid references auth.users(id) on delete set null,
  criado_em timestamptz not null default now()
);
create table if not exists public.ritmo_grupo_membros (
  grupo uuid not null references public.ritmo_grupos(id) on delete cascade,
  user_id uuid not null unique references auth.users(id) on delete cascade,   -- uma pessoa participa de um grupo por vez
  nome text not null default '',
  opts jsonb not null default '{"plant":true,"comp":true,"lemb":false,"tar":false,"gastos":false}'::jsonb,
  dados jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now(),
  primary key (grupo, user_id),
  constraint ritmo_grupo_dados_max check (pg_column_size(dados) < 400000)
);
alter table public.ritmo_grupos enable row level security;
alter table public.ritmo_grupo_membros enable row level security;
revoke all on public.ritmo_grupos, public.ritmo_grupo_membros from anon, authenticated;
grant all on public.ritmo_grupos, public.ritmo_grupo_membros to service_role;

-- Situação do meu grupo: código, o que eu compartilho e o que os outros publicaram
create or replace function public.ritmo_grupo_ver()
returns json language plpgsql stable security definer set search_path = '' as $$
declare g uuid;
begin
  if auth.uid() is null then raise exception 'sem sessão'; end if;
  select grupo into g from public.ritmo_grupo_membros where user_id = auth.uid();
  if g is null then return json_build_object('grupo', false); end if;
  return json_build_object('grupo', true,
    'codigo', (select codigo from public.ritmo_grupos where id = g),
    'eu', (select json_build_object('nome', nome, 'opts', opts) from public.ritmo_grupo_membros where user_id = auth.uid()),
    'membros', coalesce((select json_agg(json_build_object('id', left(md5(user_id::text), 8), 'nome', nome, 'opts', opts, 'dados', dados, 'atualizado_em', atualizado_em) order by nome)
                  from public.ritmo_grupo_membros where grupo = g and user_id <> auth.uid()), '[]'::json));
end $$;

create or replace function public.ritmo_grupo_criar(p_nome text)
returns json language plpgsql security definer set search_path = '' as $$
declare g uuid; c text; abc text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; i int;
begin
  if auth.uid() is null then raise exception 'sem sessão'; end if;
  if not public.ritmo_eu_ativo() then return json_build_object('ok', false, 'erro', 'Disponível para contas ativas.'); end if;
  if exists (select 1 from public.ritmo_grupo_membros where user_id = auth.uid()) then return json_build_object('ok', false, 'erro', 'Você já está em um grupo. Saia dele antes de criar outro.'); end if;
  loop
    c := ''; for i in 1..6 loop c := c || substr(abc, 1 + floor(random() * length(abc))::int, 1); end loop;
    exit when not exists (select 1 from public.ritmo_grupos where codigo = c);
  end loop;
  insert into public.ritmo_grupos(codigo, dono) values (c, auth.uid()) returning id into g;
  insert into public.ritmo_grupo_membros(grupo, user_id, nome) values (g, auth.uid(), left(coalesce(nullif(trim(p_nome), ''), 'Eu'), 30));
  return json_build_object('ok', true, 'codigo', c);
end $$;

create or replace function public.ritmo_grupo_entrar(p_codigo text, p_nome text)
returns json language plpgsql security definer set search_path = '' as $$
declare g uuid; c text := upper(regexp_replace(coalesce(p_codigo, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if auth.uid() is null then raise exception 'sem sessão'; end if;
  if not public.ritmo_eu_ativo() then return json_build_object('ok', false, 'erro', 'Disponível para contas ativas.'); end if;
  if exists (select 1 from public.ritmo_grupo_membros where user_id = auth.uid()) then return json_build_object('ok', false, 'erro', 'Você já está em um grupo. Saia dele antes de entrar em outro.'); end if;
  if c like 'RITMO%' and length(c) > 6 then c := substr(c, 6); end if;
  select id into g from public.ritmo_grupos where codigo = c;
  if g is null then perform pg_sleep(0.4); return json_build_object('ok', false, 'erro', 'Código não encontrado. Confira com quem te enviou.'); end if;
  if (select count(*) from public.ritmo_grupo_membros where grupo = g) >= 6 then return json_build_object('ok', false, 'erro', 'Esse grupo já tem 6 pessoas.'); end if;
  insert into public.ritmo_grupo_membros(grupo, user_id, nome) values (g, auth.uid(), left(coalesce(nullif(trim(p_nome), ''), 'Eu'), 30));
  return json_build_object('ok', true, 'codigo', c);
end $$;

create or replace function public.ritmo_grupo_sair()
returns json language plpgsql security definer set search_path = '' as $$
declare g uuid;
begin
  if auth.uid() is null then raise exception 'sem sessão'; end if;
  delete from public.ritmo_grupo_membros where user_id = auth.uid() returning grupo into g;
  if g is not null and not exists (select 1 from public.ritmo_grupo_membros where grupo = g) then delete from public.ritmo_grupos where id = g; end if;
  return json_build_object('ok', true);
end $$;

-- Publica o meu recorte (só o que escolhi) para o grupo
create or replace function public.ritmo_grupo_publicar(p_nome text, p_opts jsonb, p_dados jsonb)
returns json language plpgsql security definer set search_path = '' as $$
declare o jsonb := coalesce(p_opts, '{}'::jsonb); d jsonb := coalesce(p_dados, '{}'::jsonb); k text;
begin
  if auth.uid() is null then raise exception 'sem sessão'; end if;
  -- garante no servidor: o que não está marcado para compartilhar não é guardado
  foreach k in array array['plant','comp','lemb','tar','gastos'] loop
    if coalesce((o->>k)::boolean, false) is not true then d := d - k; end if;
  end loop;
  update public.ritmo_grupo_membros set
      nome = left(coalesce(nullif(trim(p_nome), ''), nome), 30),
      opts = jsonb_build_object('plant', coalesce((o->>'plant')::boolean,false), 'comp', coalesce((o->>'comp')::boolean,false),
                                'lemb', coalesce((o->>'lemb')::boolean,false), 'tar', coalesce((o->>'tar')::boolean,false), 'gastos', coalesce((o->>'gastos')::boolean,false)),
      dados = jsonb_build_object('plant', coalesce(d->'plant','[]'), 'comp', coalesce(d->'comp','[]'), 'lemb', coalesce(d->'lemb','[]'), 'tar', coalesce(d->'tar','[]'), 'gastos', coalesce(d->'gastos','[]')),
      atualizado_em = now()
   where user_id = auth.uid();
  if not found then return json_build_object('ok', false, 'erro', 'Você não está em um grupo.'); end if;
  return json_build_object('ok', true);
end $$;

revoke all on function public.ritmo_grupo_ver(), public.ritmo_grupo_criar(text), public.ritmo_grupo_entrar(text,text), public.ritmo_grupo_sair(),
  public.ritmo_grupo_publicar(text,jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.ritmo_grupo_ver(), public.ritmo_grupo_criar(text), public.ritmo_grupo_entrar(text,text), public.ritmo_grupo_sair(),
  public.ritmo_grupo_publicar(text,jsonb,jsonb) to authenticated;
notify pgrst, 'reload schema';
