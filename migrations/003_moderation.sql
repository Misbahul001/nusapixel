-- Migration 003: Sistem Moderasi (Step 3)
-- Melindungi kanvas publik dari vandalisme, menyediakan alat admin, dan pelaporan pemain.

-- 1. Konfigurasi tambahan untuk moderasi
alter table config add column if not exists daily_report_cap int default 5;
alter table config add column if not exists nick_change_cooldown_hours int default 24;

-- 2. Status blokir dan pergantian nama pada players
alter table players add column if not exists banned boolean default false;
alter table players add column if not exists last_nick_change timestamptz;

-- 3. Tabel peran (roles) untuk hak akses admin
create table if not exists roles (
  uid uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('admin', 'moderator')),
  created_at timestamptz default now()
);

alter table roles enable row level security;
create policy r_roles on roles for select using (uid = auth.uid());

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from roles where uid = auth.uid() and role = 'admin');
$$;

-- 4. Tabel laporan dari pemain (reports)
create table if not exists reports (
  id bigint generated always as identity primary key,
  reporter_id uuid default auth.uid(),
  x int,
  y int,
  target_uid uuid,
  reason text not null check (length(reason) between 3 and 250),
  status text not null default 'pending' check (status in ('pending', 'resolved', 'dismissed')),
  created_at timestamptz default now()
);

alter table reports enable row level security;
create policy r_reports_admin on reports for all using (is_admin());
create policy r_reports_user on reports for select using (reporter_id = auth.uid());

-- 5. Tabel log aksi moderasi (mod_logs)
create table if not exists mod_logs (
  id bigint generated always as identity primary key,
  admin_uid uuid default auth.uid(),
  action text not null,
  target_uid uuid,
  details jsonb,
  created_at timestamptz default now()
);

alter table mod_logs enable row level security;
create policy r_mod_logs on mod_logs for select using (is_admin());

-- 6. RPC submit_report: Pemain melaporkan titik tertentu
create or replace function submit_report(px int, py int, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  c config;
  rep_today int;
  t_uid uuid;
begin
  select * into c from config;
  me := refresh_player();
  if me.banned then raise exception 'Akun Anda diblokir'; end if;

  -- Batas laporan per pemain per hari
  select count(*) into rep_today
  from reports
  where reporter_id = auth.uid() and created_at >= (now() at time zone 'Asia/Jakarta')::date;

  if rep_today >= coalesce(c.daily_report_cap, 5) then
    raise exception 'Batas pelaporan harian tercapai (maksimal % laporan per hari)', coalesce(c.daily_report_cap, 5);
  end if;

  select uid into t_uid from pixels where x = px and y = py;

  insert into reports(reporter_id, x, y, target_uid, reason)
  values (auth.uid(), px, py, t_uid, trim(p_reason));

  return jsonb_build_object('success', true, 'message', 'Laporan berhasil dikirim dan akan ditinjau moderator');
end $$;

-- 7. Moderasi Nama Tampilan (set_nick dengan cooldown)
create or replace function set_nick(n text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  clean text := trim(n);
  me players;
  c config;
begin
  select * into c from config;
  me := refresh_player();
  if me.banned then raise exception 'Akun Anda diblokir'; end if;

  if length(clean) < 3 or length(clean) > 16 then
    raise exception 'Nama harus antara 3 sampai 16 karakter';
  end if;

  -- Cek cooldown pergantian nama
  if me.last_nick_change is not null and me.last_nick_change > now() - (coalesce(c.nick_change_cooldown_hours, 24) || ' hours')::interval then
    raise exception 'Nama tampilan hanya dapat diganti sekali setiap % jam', coalesce(c.nick_change_cooldown_hours, 24);
  end if;

  update players set nick = clean, last_nick_change = now() where id = auth.uid();
  return get_state();
end $$;

-- 8. Fungsi-fungsi Admin:
-- a. Hapus pixel dalam area persegi panjang
create or replace function admin_delete_rect(x1 int, y1 int, x2 int, y2 int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  min_x int := least(x1, x2);
  max_x int := greatest(x1, x2);
  min_y int := least(y1, y2);
  max_y int := greatest(y1, y2);
  del_count int;
  r record;
begin
  if not is_admin() then raise exception 'Hanya admin yang dapat menjalankan fungsi ini'; end if;

  with del as (
    delete from pixels
    where x between min_x and max_x and y between min_y and max_y
    returning x, y
  )
  select count(*) into del_count from del;

  insert into mod_logs(action, details)
  values ('delete_rect', jsonb_build_object('x1', min_x, 'y1', min_y, 'x2', max_x, 'y2', max_y, 'count', del_count));

  return jsonb_build_object('success', true, 'deleted_pixels', del_count);
end $$;

-- b. Hapus semua pixel milik satu pemain
create or replace function admin_delete_player_pixels(p_uid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  del_count int;
begin
  if not is_admin() then raise exception 'Hanya admin yang dapat menjalankan fungsi ini'; end if;

  with del as (
    delete from pixels where uid = p_uid returning x, y
  )
  select count(*) into del_count from del;

  insert into mod_logs(action, target_uid, details)
  values ('delete_player_pixels', p_uid, jsonb_build_object('count', del_count));

  return jsonb_build_object('success', true, 'deleted_pixels', del_count);
end $$;

-- c. Blokir / Buka blokir pemain
create or replace function admin_toggle_ban(p_uid uuid, p_ban boolean, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Hanya admin yang dapat menjalankan fungsi ini'; end if;

  update players set banned = p_ban where id = p_uid;

  insert into mod_logs(action, target_uid, details)
  values (case when p_ban then 'ban_player' else 'unban_player' end, p_uid, jsonb_build_object('reason', p_reason));

  return jsonb_build_object('success', true, 'banned', p_ban);
end $$;

-- d. Reset nama tampilan yang tidak pantas
create or replace function admin_reset_nick(p_uid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Hanya admin yang dapat menjalankan fungsi ini'; end if;

  update players set nick = null where id = p_uid;

  insert into mod_logs(action, target_uid, details)
  values ('reset_nick', p_uid, '{}'::jsonb);

  return jsonb_build_object('success', true, 'message', 'Nama berhasil direset');
end $$;

-- e. Update status laporan (resolve/dismiss)
create or replace function admin_resolve_report(p_rep_id bigint, p_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Hanya admin yang dapat menjalankan fungsi ini'; end if;
  if p_status not in ('resolved', 'dismissed') then raise exception 'Status tidak valid'; end if;

  update reports set status = p_status where id = p_rep_id;
  return jsonb_build_object('success', true, 'status', p_status);
end $$;

-- f. Bersihkan log lama (> 30 hari)
create or replace function admin_cleanup_logs() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cleaned int;
begin
  if not is_admin() then raise exception 'Hanya admin yang dapat menjalankan fungsi ini'; end if;

  with d as (
    delete from mod_logs where created_at < now() - interval '30 days' returning 1
  )
  select count(*) into cleaned from d;

  return jsonb_build_object('success', true, 'cleaned_rows', cleaned);
end $$;
