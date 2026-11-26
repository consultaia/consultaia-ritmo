-- Ritmo — banco no projeto dri-imoveis, isolado no schema "ritmo".
-- Não cria, altera nem lê nada do schema public (tabelas do imobiliário).
-- Rodar uma vez em: Supabase > dri-imoveis > SQL Editor.

create schema if not exists ritmo;

-- Um documento por usuário com todo o estado do app (perfis, tarefas, hábitos, gastos…).
create table if not exists ritmo.estado (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  dados         jsonb       not null default '{}'::jsonb,
  versao_app    text,
  atualizado_em timestamptz not null default now(),
  criado_em     timestamptz not null default now()
);

-- Atualiza o carimbo de tempo a cada gravação (usado para resolver conflito entre aparelhos).
create or replace function ritmo.tocar_atualizado_em()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.atualizado_em := now();
  return new;
end $$;

drop trigger if exists trg_estado_atualizado on ritmo.estado;
create trigger trg_estado_atualizado before insert or update on ritmo.estado
  for each row execute function ritmo.tocar_atualizado_em();

-- Segurança: cada pessoa só enxerga e grava o próprio estado.
alter table ritmo.estado enable row level security;

drop policy if exists "ritmo_estado_select_proprio" on ritmo.estado;
create policy "ritmo_estado_select_proprio" on ritmo.estado
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "ritmo_estado_insert_proprio" on ritmo.estado;
create policy "ritmo_estado_insert_proprio" on ritmo.estado
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists "ritmo_estado_update_proprio" on ritmo.estado;
create policy "ritmo_estado_update_proprio" on ritmo.estado
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists "ritmo_estado_delete_proprio" on ritmo.estado;
create policy "ritmo_estado_delete_proprio" on ritmo.estado
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Permissões da API (anon não recebe nada; só usuário logado).
grant usage on schema ritmo to authenticated;
grant select, insert, update, delete on ritmo.estado to authenticated;
revoke all on ritmo.estado from anon;

-- Limite de tamanho por usuário (evita abuso do plano): 2 MB por documento.
alter table ritmo.estado drop constraint if exists estado_tamanho_max;
alter table ritmo.estado add constraint estado_tamanho_max check (pg_column_size(dados) < 2097152);

-- Faz a API recarregar o cache de schemas.
notify pgrst, 'reload schema';
