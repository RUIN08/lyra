-- =========================================================
--  Lyra (노래 추천 앱) — Supabase 초기 설정 SQL
--  Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 Run
-- =========================================================

-- 1) 프로필 (닉네임 시스템)
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  username text unique not null,
  nickname text unique not null,
  color text default '#a78bfa',
  created_at timestamptz default now()
);

-- 2) 추천 노래
create table if not exists public.songs (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  artist text default '',
  source text not null check (source in ('youtube','mp3','mp4')),
  youtube_id text,
  file_path text,
  file_name text,
  file_size bigint,
  tags text[] default '{}',
  note text default '',
  created_at timestamptz default now()
);

-- 3) 리뷰 (별점 + 5개 영역 점수 + 한줄평 + 리뷰)
create table if not exists public.reviews (
  id bigint generated always as identity primary key,
  song_id bigint not null references public.songs(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  stars numeric(2,1) not null check (stars between 0.5 and 5),
  s_melody smallint not null check (s_melody between 1 and 10),
  s_lyrics smallint not null check (s_lyrics between 1 and 10),
  s_vocal  smallint not null check (s_vocal  between 1 and 10),
  s_sound  smallint not null check (s_sound  between 1 and 10),
  s_mood   smallint not null check (s_mood   between 1 and 10),
  one_line text not null check (char_length(one_line) between 1 and 60),
  body text default '',
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (song_id, user_id)
);

-- 4) 좋아요
create table if not exists public.likes (
  song_id bigint not null references public.songs(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz default now(),
  primary key (song_id, user_id)
);

-- 5) 보안 규칙 (누구나 보기 / 본인 것만 쓰기·수정·삭제)
alter table public.profiles enable row level security;
alter table public.songs    enable row level security;
alter table public.reviews  enable row level security;
alter table public.likes    enable row level security;

create policy "profiles read"   on public.profiles for select using (true);
create policy "profiles update" on public.profiles for update to authenticated using (auth.uid() = id);

create policy "songs read"   on public.songs for select using (true);
create policy "songs insert" on public.songs for insert to authenticated with check (auth.uid() = user_id);
create policy "songs update" on public.songs for update to authenticated using (auth.uid() = user_id);
create policy "songs delete" on public.songs for delete to authenticated using (auth.uid() = user_id);

create policy "reviews read"   on public.reviews for select using (true);
create policy "reviews insert" on public.reviews for insert to authenticated with check (auth.uid() = user_id);
create policy "reviews update" on public.reviews for update to authenticated using (auth.uid() = user_id);
create policy "reviews delete" on public.reviews for delete to authenticated using (auth.uid() = user_id);

create policy "likes read"   on public.likes for select using (true);
create policy "likes insert" on public.likes for insert to authenticated with check (auth.uid() = user_id);
create policy "likes delete" on public.likes for delete to authenticated using (auth.uid() = user_id);

-- API 접근 권한 (보안 규칙은 위 RLS가 담당)
grant select on public.profiles, public.songs, public.reviews, public.likes to anon, authenticated;
grant insert, update, delete on public.songs, public.reviews, public.likes to authenticated;
grant update on public.profiles to authenticated;

-- 6) 회원가입하면 프로필 자동 생성
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username, nickname, color)
  values (
    new.id,
    new.raw_user_meta_data->>'username',
    new.raw_user_meta_data->>'nickname',
    coalesce(new.raw_user_meta_data->>'color', '#a78bfa')
  );
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 7) mp3/mp4 파일 저장소 (공개 읽기, 50MB 제한)
insert into storage.buckets (id, name, public, file_size_limit)
values ('songs', 'songs', true, 52428800)
on conflict (id) do nothing;

create policy "song files read" on storage.objects
  for select using (bucket_id = 'songs');
create policy "song files upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'songs' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "song files delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'songs' and (storage.foldername(name))[1] = auth.uid()::text);

-- 8) RE87 프로필 꾸미기 (2026-11-23 추가)
alter table public.profiles
  add column if not exists avatar_url text,
  add column if not exists bio text default '',
  add column if not exists banner text,
  add column if not exists fav_tags text[] default '{}',
  add column if not exists pinned_song bigint references public.songs(id) on delete set null;
