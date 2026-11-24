-- =====================================================================
-- RE87 v3 업데이트: 플레이리스트 + 사용법 가이드 기록
-- Supabase → SQL Editor에 붙여넣고 Run 하세요. 여러 번 실행해도 안전해요.
-- (security_patch.sql을 아직 안 돌렸다면 그것도 함께 실행해 주세요)
-- =====================================================================

-- 1) 가이드를 본 유저 기록 (다른 기기에서 접속해도 다시 안 뜨게)
alter table public.profiles add column if not exists guide_done boolean not null default false;

-- security_patch.sql로 프로필 수정 컬럼을 제한했다면, guide_done도 수정 가능하게 허용
do $$ begin
  if exists (select 1 from information_schema.column_privileges
             where table_schema='public' and table_name='profiles' and grantee='authenticated' and privilege_type='UPDATE') then
    execute 'grant update (guide_done) on public.profiles to authenticated';
  end if;
end $$;

-- 2) 플레이리스트
create table if not exists public.playlists (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  name        text not null check (char_length(name) between 1 and 40),
  description text not null default '' check (char_length(description) <= 200),
  color       text not null default '#6ff0b6' check (color ~ '^#[0-9a-fA-F]{3,8}$'),
  is_public   boolean not null default true,
  song_ids    bigint[] not null default '{}' check (cardinality(song_ids) <= 500),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists playlists_user_idx on public.playlists(user_id);

alter table public.playlists enable row level security;

drop policy if exists "playlists_read"   on public.playlists;
drop policy if exists "playlists_insert" on public.playlists;
drop policy if exists "playlists_update" on public.playlists;
drop policy if exists "playlists_delete" on public.playlists;

-- 공개 플레이리스트는 누구나, 비공개는 만든 사람만 볼 수 있어요
create policy "playlists_read"   on public.playlists for select using (is_public or auth.uid() = user_id);
create policy "playlists_insert" on public.playlists for insert to authenticated with check (auth.uid() = user_id);
create policy "playlists_update" on public.playlists for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "playlists_delete" on public.playlists for delete to authenticated using (auth.uid() = user_id);

-- 수정 시간은 서버가 기록
create or replace function public.playlists_touch() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if tg_op = 'INSERT' then new.created_at := now(); end if;
  return new;
end $$;
drop trigger if exists playlists_touch on public.playlists;
create trigger playlists_touch before insert or update on public.playlists
  for each row execute function public.playlists_touch();

-- 한 사람당 플레이리스트 100개까지
create or replace function public.playlists_limit() returns trigger language plpgsql as $$
begin
  if (select count(*) from public.playlists where user_id = new.user_id) >= 100 then
    raise exception '플레이리스트는 100개까지 만들 수 있어요';
  end if;
  return new;
end $$;
drop trigger if exists playlists_limit on public.playlists;
create trigger playlists_limit before insert on public.playlists
  for each row execute function public.playlists_limit();

grant select on public.playlists to anon, authenticated;
grant insert, update, delete on public.playlists to authenticated;
