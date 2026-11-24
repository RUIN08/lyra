-- =========================================================
--  RE87 보안 보강 SQL (검토 결과 반영) — Supabase SQL Editor에서 통째로 Run
--  여러 번 실행해도 안전하도록 작성됨
-- =========================================================

-- 1) 프로필: 바꿀 수 있는 칸 제한 + 값 검사
revoke update on public.profiles from authenticated;
grant update (nickname, color, bio, banner, avatar_url, fav_tags, pinned_song) on public.profiles to authenticated;

drop policy if exists "profiles update" on public.profiles;
create policy "profiles update" on public.profiles for update to authenticated
  using (auth.uid() = id)
  with check (
    auth.uid() = id
    and (pinned_song is null or exists (select 1 from public.songs s where s.id = pinned_song and s.user_id = auth.uid()))
    and (avatar_url is null
         or avatar_url ~ '^preset:.{1,8}$'
         or avatar_url like 'https://qpnrngukoiixmzinjstl.supabase.co/storage/v1/object/public/songs/' || auth.uid()::text || '/avatar\_%')
  );

alter table public.profiles drop constraint if exists profiles_color_fmt;
alter table public.profiles add  constraint profiles_color_fmt check (color ~ '^#[0-9a-fA-F]{6}$') not valid;
alter table public.profiles drop constraint if exists profiles_nickname_fmt;
alter table public.profiles add  constraint profiles_nickname_fmt check (nickname = btrim(nickname) and char_length(nickname) between 2 and 12) not valid;
alter table public.profiles drop constraint if exists profiles_bio_len;
alter table public.profiles add  constraint profiles_bio_len check (char_length(coalesce(bio,'')) <= 120) not valid;
alter table public.profiles drop constraint if exists profiles_banner_enum;
alter table public.profiles add  constraint profiles_banner_enum check (banner is null or banner in ('aurora','sunset','night','ocean','candy','mono','gold')) not valid;
alter table public.profiles drop constraint if exists profiles_fav_tags;
alter table public.profiles add  constraint profiles_fav_tags check (cardinality(coalesce(fav_tags,'{}')) <= 5) not valid;

-- 2) 회원가입: 아이디는 이메일에서만 가져오고 값 검사
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  uname text := lower(split_part(new.email, '@', 1));
  nick  text := btrim(coalesce(new.raw_user_meta_data->>'nickname', ''));
  col   text := new.raw_user_meta_data->>'color';
begin
  if new.email is null or lower(split_part(new.email, '@', 2)) <> 'lyra.local' then
    raise exception 'signup not allowed';
  end if;
  if uname !~ '^[a-z0-9_]{3,20}$' then raise exception 'invalid username'; end if;
  if col is null or col !~ '^#[0-9a-fA-F]{6}$' then col := '#a78bfa'; end if;
  insert into public.profiles (id, username, nickname, color) values (new.id, uname, nick, col);
  return new;
end; $$;

-- 3) 노래: 길이·형식 제한, 다른 사람 파일 가리키기 금지
alter table public.songs drop constraint if exists songs_lengths;
alter table public.songs add constraint songs_lengths check (
  char_length(btrim(title)) between 1 and 100
  and char_length(coalesce(artist,'')) <= 100
  and char_length(coalesce(note,'')) <= 500
  and char_length(coalesce(file_name,'')) <= 200
  and cardinality(coalesce(tags,'{}')) <= 10) not valid;
alter table public.songs drop constraint if exists songs_source_shape;
alter table public.songs add constraint songs_source_shape check (
  (source = 'youtube' and youtube_id ~ '^[A-Za-z0-9_-]{11}$' and file_path is null)
  or (source in ('mp3','mp4') and youtube_id is null and file_path is not null)) not valid;

drop policy if exists "songs insert" on public.songs;
create policy "songs insert" on public.songs for insert to authenticated
  with check (auth.uid() = user_id and (file_path is null or split_part(file_path,'/',1) = auth.uid()::text));
drop policy if exists "songs update" on public.songs;
create policy "songs update" on public.songs for update to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id and (file_path is null or split_part(file_path,'/',1) = auth.uid()::text));

-- 4) 리뷰 본문 길이
alter table public.reviews drop constraint if exists reviews_body_len;
alter table public.reviews add constraint reviews_body_len check (char_length(coalesce(body,'')) <= 3000) not valid;

-- 5) 시간은 서버가 정함 (인기 차트 조작 방지)
create or replace function public.force_ts() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then new.created_at := now(); else new.created_at := old.created_at; end if;
  if tg_table_name = 'reviews' then new.updated_at := now(); end if;
  return new;
end; $$;
drop trigger if exists songs_force_ts   on public.songs;
create trigger songs_force_ts   before insert or update on public.songs   for each row execute function public.force_ts();
drop trigger if exists reviews_force_ts on public.reviews;
create trigger reviews_force_ts before insert or update on public.reviews for each row execute function public.force_ts();
drop trigger if exists likes_force_ts   on public.likes;
create trigger likes_force_ts   before insert on public.likes for each row execute function public.force_ts();

-- 6) 파일 저장소: MP3·MP4·JPG만, 사람당 60개까지
update storage.buckets
   set allowed_mime_types = array['audio/mpeg','audio/mp3','video/mp4','image/jpeg'],
       file_size_limit = 52428800
 where id = 'songs';

drop policy if exists "song files upload" on storage.objects;
create policy "song files upload" on storage.objects for insert to authenticated
with check (
  bucket_id = 'songs'
  and (storage.foldername(name))[1] = auth.uid()::text
  and lower(storage.extension(name)) in ('mp3','mp4','jpg')
  and (select count(*) from storage.objects o
        where o.bucket_id = 'songs' and (storage.foldername(o.name))[1] = auth.uid()::text) < 60
);
