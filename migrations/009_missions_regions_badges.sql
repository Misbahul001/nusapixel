-- ==============================================================================
-- Migrasi 009: Misi Jelajah, Wilayah Provinsi, Lencana & Profil (Step 13)
-- ==============================================================================

-- 1. Refaktor Misi: Tabel Missions sebagai Single Source of Truth
create table if not exists missions (
  id text primary key,
  kind text not null default 'day_placed', -- 'day_placed', 'explore_regions'
  need int not null,
  reward_stock int not null default 0,
  reward_boost_min int not null default 0,
  title text not null
);

alter table missions enable row level security;
drop policy if exists "missions_read_all" on missions;
create policy "missions_read_all" on missions for select to public using (true);

-- Isi misi bawaan (mempertahankan perilaku m50, m200, m500 secara persis)
insert into missions (id, kind, need, reward_stock, reward_boost_min, title) values
  ('m50', 'day_placed', 50, 50, 0, 'Pasang 50 pixel'),
  ('m200', 'day_placed', 200, 0, 30, 'Pasang 200 pixel'),
  ('m500', 'day_placed', 500, 150, 0, 'Pasang 500 pixel'),
  ('m_explore_3', 'explore_regions', 3, 30, 15, 'Jelajah 3 provinsi')
on conflict (id) do update set
  kind = excluded.kind,
  need = excluded.need,
  reward_stock = excluded.reward_stock,
  reward_boost_min = excluded.reward_boost_min,
  title = excluded.title;

-- Fungsi untuk membaca seluruh misi aktif
create or replace function get_missions() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(m)), '[]'::jsonb)
  from (select * from missions order by need asc) m;
$$;

-- 2. Wilayah / Kotak Kasar 38 Provinsi Indonesia
-- Koordinat grid (x = lng/0.001, y = lat/0.001)
create table if not exists regions (
  id serial primary key,
  name text not null,
  min_x int not null,
  max_x int not null,
  min_y int not null,
  max_y int not null
);

alter table regions enable row level security;
drop policy if exists "regions_read_all" on regions;
create policy "regions_read_all" on regions for select to public using (true);

-- Kolom pelacak di tabel players
alter table players add column if not exists regions_today int[] default '{}';
alter table players add column if not exists regions_alltime int[] default '{}';
alter table players add column if not exists best_streak int default 0;

-- Seed 38 Provinsi Indonesia (Bounding box kasar sesuai aturan #10)
truncate table regions restart identity;
insert into regions (name, min_x, max_x, min_y, max_y) values
  ('Aceh', 95000, 98300, 1900, 6000),
  ('Sumatera Utara', 97000, 100100, 500, 4300),
  ('Sumatera Barat', 98500, 101900, -3400, 900),
  ('Riau', 100000, 103800, -1200, 2500),
  ('Kepulauan Riau', 103500, 109200, -700, 5000),
  ('Jambi', 101100, 104500, -2800, -700),
  ('Sumatera Selatan', 102000, 106200, -4900, -1600),
  ('Kepulauan Bangka Belitung', 105000, 108800, -3700, -1300),
  ('Bengkulu', 101000, 103800, -5500, -2200),
  ('Lampung', 103500, 106000, -6100, -3700),
  ('Banten', 105100, 106800, -7000, -5800),
  ('DKI Jakarta', 106680, 106980, -6370, -6080),
  ('Jawa Barat', 106300, 108800, -7800, -5900),
  ('Jawa Tengah', 108500, 111600, -8200, -6400),
  ('DI Yogyakarta', 110000, 110800, -8200, -7500),
  ('Jawa Timur', 110800, 114600, -8800, -6700),
  ('Bali', 114400, 115700, -8900, -8000),
  ('Nusa Tenggara Barat', 115800, 119400, -9200, -8000),
  ('Nusa Tenggara Timur', 118900, 125200, -11000, -8000),
  ('Kalimantan Barat', 108500, 114200, -3100, 2100),
  ('Kalimantan Tengah', 110700, 115900, -3600, 800),
  ('Kalimantan Selatan', 114300, 116600, -4200, -1300),
  ('Kalimantan Timur', 114500, 119100, -2500, 2500),
  ('Kalimantan Utara', 114500, 118000, 1100, 4400),
  ('Sulawesi Utara', 123100, 127200, 200, 5600),
  ('Gorontalo', 121100, 123600, 300, 1100),
  ('Sulawesi Tengah', 119300, 124400, -3600, 1400),
  ('Sulawesi Barat', 118700, 119900, -3600, -800),
  ('Sulawesi Selatan', 118400, 122300, -7500, -1800),
  ('Sulawesi Tenggara', 120800, 124600, -6300, -2800),
  ('Maluku', 125700, 135000, -8400, -1400),
  ('Maluku Utara', 124200, 129700, -2500, 2700),
  ('Papua Barat', 130100, 135300, -4400, 300),
  ('Papua Barat Daya', 129500, 134000, -2300, 1200),
  ('Papua', 134100, 141000, -3500, 100),
  ('Papua Tengah', 134500, 138500, -5500, -2500),
  ('Papua Pegunungan', 137500, 141000, -5100, -3300),
  ('Papua Selatan', 137000, 141000, -9200, -4500);

-- 3. Tabel Lencana (Badges) & Lencana Pemain
create table if not exists badges (
  id text primary key,
  name text not null,
  description text not null
);

alter table badges enable row level security;
drop policy if exists "badges_read_all" on badges;
create policy "badges_read_all" on badges for select to public using (true);

insert into badges (id, name, description) values
  ('pixel_100', 'Pembuat Jejak', 'Memasang total 100 pixel di kanvas'),
  ('pixel_1k', 'Seniman Kanvas', 'Memasang total 1.000 pixel di kanvas'),
  ('pixel_10k', 'Legenda Pixel', 'Memasang total 10.000 pixel di kanvas'),
  ('streak_7', 'Semangat Mingguan', 'Mencapai 7 hari streak login harian'),
  ('streak_30', 'Dedikasi Bulanan', 'Mencapai 30 hari streak login harian'),
  ('streak_100', 'Ikon Nusantara', 'Mencapai 100 hari streak login harian'),
  ('explorer_10', 'Penjelajah Nusantara', 'Menggambar di 10 provinsi berbeda')
on conflict (id) do update set
  name = excluded.name,
  description = excluded.description;

create table if not exists player_badges (
  uid uuid not null references auth.users(id) on delete cascade,
  badge text not null references badges(id) on delete cascade,
  at timestamptz not null default now(),
  primary key (uid, badge)
);

alter table player_badges enable row level security;
drop policy if exists "player_badges_read_all" on player_badges;
create policy "player_badges_read_all" on player_badges for select to public using (true);

-- Fungsi server untuk mengecek dan memberikan lencana otomatis (aturan #12: klien tidak bisa memberi lencana)
create or replace function check_and_award_badges(p_uid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  p players;
  reg_count int;
  s_max int;
begin
  select * into p from players where id = p_uid;
  if not found then return; end if;

  -- 1. Lencana Total Pixel
  if coalesce(p.total_placed, 0) >= 100 then
    insert into player_badges(uid, badge) values (p_uid, 'pixel_100') on conflict do nothing;
  end if;
  if coalesce(p.total_placed, 0) >= 1000 then
    insert into player_badges(uid, badge) values (p_uid, 'pixel_1k') on conflict do nothing;
  end if;
  if coalesce(p.total_placed, 0) >= 10000 then
    insert into player_badges(uid, badge) values (p_uid, 'pixel_10k') on conflict do nothing;
  end if;

  -- 2. Lencana Streak
  s_max := greatest(coalesce(p.streak, 0), coalesce(p.best_streak, 0));
  if s_max >= 7 then
    insert into player_badges(uid, badge) values (p_uid, 'streak_7') on conflict do nothing;
  end if;
  if s_max >= 30 then
    insert into player_badges(uid, badge) values (p_uid, 'streak_30') on conflict do nothing;
  end if;
  if s_max >= 100 then
    insert into player_badges(uid, badge) values (p_uid, 'streak_100') on conflict do nothing;
  end if;

  -- 3. Lencana Jelajah (10 provinsi)
  reg_count := coalesce(array_length(p.regions_alltime, 1), 0);
  if reg_count >= 10 then
    insert into player_badges(uid, badge) values (p_uid, 'explorer_10') on conflict do nothing;
  end if;
end $$;

-- 4. Pembaruan claim_mission(mid text) dengan pembacaan dinamis dari tabel missions
create or replace function claim_mission(mid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  m missions;
  progress int;
  s_reward int;
  b_reward interval;
begin
  me := refresh_player();
  if me.banned then raise exception 'Akun Anda diblokir karena melanggar aturan komunitas'; end if;

  select * into m from missions where id = mid;
  if not found then raise exception 'Misi tidak ditemukan'; end if;
  if mid = any(me.claimed) then raise exception 'Misi sudah diklaim'; end if;

  if m.kind = 'day_placed' then
    progress := coalesce(me.day_placed, 0);
  elsif m.kind = 'explore_regions' then
    progress := coalesce(array_length(me.regions_today, 1), 0);
  else
    progress := 0;
  end if;

  if progress < m.need then raise exception 'Misi belum selesai'; end if;

  s_reward := m.reward_stock;
  b_reward := (m.reward_boost_min || ' minutes')::interval;

  update players set
    claimed = claimed || mid,
    stock = stock + s_reward,
    boost_until = case when m.reward_boost_min > 0 then greatest(now(), boost_until) + b_reward else boost_until end
  where id = me.id;

  -- Cek & berikan lencana
  perform check_and_award_badges(me.id);

  return get_state();
end $$;

-- 5. Profil Pemain RPC (get_player_profile)
create or replace function get_player_profile(p_uid uuid default auth.uid()) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  target_id uuid := coalesce(p_uid, auth.uid());
  p players;
  badges_json jsonb;
begin
  if target_id is null then raise exception 'Pengguna tidak ditemukan'; end if;
  select * into p from players where id = target_id;
  if not found then raise exception 'Profil pemain belum tersedia'; end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', b.id,
      'name', b.name,
      'description', b.description,
      'earned', pb.at is not null,
      'earned_at', pb.at
    ) order by b.id asc
  ), '[]'::jsonb)
  into badges_json
  from badges b
  left join player_badges pb on pb.badge = b.id and pb.uid = target_id;

  return jsonb_build_object(
    'id', p.id,
    'nick', coalesce(p.nick, 'Anonim'),
    'trust_level', coalesce(p.trust_level, 1),
    'total_placed', coalesce(p.total_placed, 0),
    'day_placed', coalesce(p.day_placed, 0),
    'streak', coalesce(p.streak, 0),
    'best_streak', coalesce(p.best_streak, coalesce(p.streak, 0)),
    'regions_today_count', coalesce(array_length(p.regions_today, 1), 0),
    'regions_alltime_count', coalesce(array_length(p.regions_alltime, 1), 0),
    'badges', badges_json
  );
end $$;
