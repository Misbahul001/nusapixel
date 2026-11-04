-- Jalankan seluruh file ini di Supabase > SQL Editor.
-- Aktifkan juga: Authentication > Sign In / Providers > "Allow anonymous sign-ins".

-- Bersihkan fungsi terlebih dahulu untuk mencegah konflik tipe return dari migrasi lama
drop function if exists refresh_heat() cascade;
drop function if exists get_missions() cascade;
drop function if exists claim_mission(text) cascade;
drop function if exists get_player_profile(uuid) cascade;

-- ===== PENGATURAN (ubah angka di sini kapan saja) =====
create table if not exists config(
  id int primary key default 1 check (id = 1),
  max_stock int default 500,             -- stok maksimal
  start_stock int default 75,            -- stok pemain baru
  refill_sec numeric default 8,          -- detik per 1 pixel (normal)
  boost_refill_sec numeric default 4,    -- detik per 1 pixel (saat boost)
  min_x int default 94900, max_x int default 141100,
  min_y int default -11100, max_y int default 6300,
  ad_reward int default 25,              -- pixel instan per iklan
  ad_daily_cap int default 5,            -- maks. iklan per pemain per hari
  ad_cooldown_sec int default 180,       -- jeda antar iklan
  ad_min_sec int default 15,             -- waktu minimal sejak iklan dimulai
  max_batch_size int default 20,         -- maks. pixel per permintaan
  rate_limit_px_per_sec numeric default 5, -- maks. pixel per detik per pemain
  daily_report_cap int default 5,        -- maks. laporan per pemain per hari
  nick_change_cooldown_hours int default 24, -- jeda pergantian nama
  info_cooldown_ms int default 500,      -- jeda inspeksi info pixel (ms)
  event_max_mult numeric default 4,      -- batas maksimal pengali event (Step 12)
  global_boost_until timestamptz,        -- boost global komunitas (Step 12)
  protect_cost int default 5,            -- biaya lindungi pixel (Step 17)
  protect_duration_hours int default 24, -- durasi lindungi pixel (Step 17)
  max_protected_per_player int default 25, -- maks pixel terlindungi per pemain (Step 17)
  team_change_cooldown_days int default 7, -- jeda ganti tim provinsi (Step 18)
  invite_reward int default 100,         -- hadiah undangan (Step 19)
  invite_max_claimed int default 10,     -- batas klaim undangan (Step 19)
  invite_min_placed int default 100      -- syarat pixel teman (Step 19)
);
insert into config default values on conflict (id) do nothing;

create table if not exists pixels(
  x int, y int,
  c smallint not null check (c between 0 and 15),
  uid uuid, updated_at timestamptz default now(),
  protected_until timestamptz,
  cx int generated always as (floor(x::numeric / 64)::int) stored,
  cy int generated always as (floor(y::numeric / 64)::int) stored,
  primary key (x, y)
);
create index if not exists idx_pixels_chunk on pixels(cx, cy);

create table if not exists players(
  id uuid primary key,
  stock numeric not null,
  stock_at timestamptz default now(),
  boost_until timestamptz default now(),
  streak int default 0,
  last_daily date,
  day date default current_date,
  day_placed int default 0,
  claimed text[] default '{}',
  nick text,                          -- nama tampilan di peringkat
  total_placed bigint default 0,      -- total pixel yang pernah dipasang
  ads_today int default 0,            -- iklan yang sudah ditonton hari ini
  last_ad_at timestamptz,
  ad_started_at timestamptz,
  last_placed_at timestamptz default now(), -- waktu pasang terakhir untuk pembatasan laju
  banned boolean default false,       -- status blokir pemain oleh moderator
  last_nick_change timestamptz,       -- waktu terakhir ganti nama
  trust_level int default 1,          -- tingkat kepercayaan (1: pemula, 2: penjelajah, 3: pelukis, 4: master)
  max_stock int default 75,           -- batas stok dinamis sesuai reputasi
  active_days int default 1,          -- jumlah hari aktif
  regions_today int[] default '{}',   -- daftar wilayah provinsi hari ini (Step 13)
  regions_alltime int[] default '{}', -- daftar seluruh provinsi yang pernah dijelajahi
  best_streak int default 0,          -- rekor streak login harian terbaik
  created_at timestamptz default now(),
  last_info_at timestamptz            -- waktu kueri inspeksi info pixel terakhir
);

alter table config  enable row level security;
alter table pixels  enable row level security;
alter table players enable row level security;
drop policy if exists r on config;
create policy r on config  for select using (true);
drop policy if exists r on pixels;
create policy r on pixels  for select using (true);
drop policy if exists r on players;
create policy r on players for select using (id = auth.uid());
-- Tidak ada policy insert/update: semua perubahan lewat fungsi di bawah.

do $$
begin
  alter publication supabase_realtime add table pixels;
exception when others then null;
end $$;

create or replace function jkt() returns date language sql stable as
$$ select (now() at time zone 'Asia/Jakarta')::date $$;

-- Hitung isi ulang stok (pecahan disimpan, jadi tidak ada yang hilang)
create or replace function refresh_player() returns players
language plpgsql security definer set search_path = public as $$
declare
  c config;
  p players;
  el numeric;
  bs numeric;
  is_anon boolean;
  calc_max int;
  calc_lvl int;
  effective_boost timestamptz;
  event_mult numeric := 1;
begin
  select * into c from config;
  insert into players(id, stock, max_stock) values (auth.uid(), c.start_stock, c.start_stock) on conflict do nothing;
  select * into p from players where id = auth.uid() for update;

  -- Cek status anonimitas dari JWT
  is_anon := coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false);

  -- Hitung hari aktif saat berganti hari WIB
  if p.day <> jkt() then
    p.day := jkt();
    p.day_placed := 0;
    p.claimed := '{}';
    p.ads_today := 0;
    p.regions_today := '{}';
    p.active_days := coalesce(p.active_days, 1) + 1;
  end if;

  -- Kalkulasi Tingkat Kepercayaan (Trust Level) & Stok Maksimal:
  -- Level 4 (Master): Login Google/Email, aktif >= 5 hari atau streak >= 3, total_placed >= 500 -> Stok 500
  -- Level 3 (Pelukis): Login Google/Email, aktif >= 3 hari, total_placed >= 150 -> Stok 300
  -- Level 2 (Penjelajah): Aktif >= 2 hari dan total_placed >= 50 -> Stok 150
  -- Level 1 (Pemula): Akun baru / tamu anonim -> Stok 75
  if not is_anon and coalesce(p.total_placed, 0) >= 500 and (coalesce(p.active_days, 1) >= 5 or coalesce(p.streak, 0) >= 3) then
    calc_lvl := 4;
    calc_max := coalesce(c.max_stock, 500);
  elsif not is_anon and coalesce(p.total_placed, 0) >= 150 and coalesce(p.active_days, 1) >= 3 then
    calc_lvl := 3;
    calc_max := 300;
  elsif coalesce(p.total_placed, 0) >= 50 and coalesce(p.active_days, 1) >= 2 then
    calc_lvl := 2;
    calc_max := 150;
  else
    calc_lvl := 1;
    calc_max := coalesce(c.start_stock, 75);
  end if;

  p.trust_level := calc_lvl;
  p.max_stock := calc_max;

  -- Boost efektif: gabungan boost pribadi pemain dan boost global komunitas (Step 12)
  effective_boost := greatest(
    coalesce(p.boost_until, '-infinity'::timestamptz),
    coalesce(c.global_boost_until, '-infinity'::timestamptz)
  );

  -- Pengali pengisian event aktif (Step 12)
  if exists (select 1 from information_schema.tables where table_name = 'events') then
    select least(coalesce(refill_mult, 1), coalesce(c.event_max_mult, 4))
    into event_mult
    from events
    where now() between starts_at and ends_at
    order by id desc limit 1;
  end if;
  event_mult := coalesce(event_mult, 1);
  if event_mult < 1 then event_mult := 1; end if;

  -- Hitung isi ulang stok hingga batas max_stock milik pemain
  el := extract(epoch from now() - p.stock_at);
  bs := greatest(0, extract(epoch from least(now(), effective_boost) - p.stock_at));
  if p.stock < p.max_stock then
    p.stock := least(p.max_stock, p.stock + (bs * event_mult) / c.boost_refill_sec + ((el - bs) * event_mult) / c.refill_sec);
  end if;
  p.stock_at := now();

  update players set
    stock = p.stock,
    stock_at = p.stock_at,
    day = p.day,
    day_placed = p.day_placed,
    claimed = p.claimed,
    regions_today = p.regions_today,
    ads_today = p.ads_today,
    active_days = p.active_days,
    trust_level = p.trust_level,
    max_stock = p.max_stock
  where id = p.id;

  return p;
end $$;

create or replace function get_state() returns jsonb
language sql security definer set search_path = public as
$$ select to_jsonb(refresh_player()) $$;

-- Memuat sekumpulan chunk sekaligus (Step 2: Realtime per wilayah / chunk)
create or replace function get_chunks(chunks jsonb)
returns table(x int, y int, c smallint)
language sql stable security definer set search_path = public as $$
  select p.x, p.y, p.c
  from pixels p
  join jsonb_to_recordset(chunks) as req(cx int, cy int)
    on p.cx = req.cx and p.cy = req.cy;
$$;

create or replace function place_pixels(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  cfg config;
  v_batch_len int := jsonb_array_length(p);
  new_count int;
  current_goal_n bigint;
  v_rec record;
begin
  select * into cfg from config;

  -- Validasi ukuran batch dari config
  if v_batch_len < 1 or v_batch_len > coalesce(cfg.max_batch_size, 50) then
    raise exception 'Ukuran batch tidak valid (maksimal %)', coalesce(cfg.max_batch_size, 50);
  end if;

  -- Validasi koordinat wilayah Indonesia
  if exists (select 1 from jsonb_to_recordset(p) as t(x int, y int)
             where t.x not between cfg.min_x and cfg.max_x or t.y not between cfg.min_y and cfg.max_y) then
    raise exception 'Kanvas hanya mencakup wilayah Indonesia';
  end if;

  me := refresh_player();
  if me.banned then raise exception 'Akun Anda diblokir karena melanggar aturan komunitas'; end if;

  -- Filter pixel yang terlindungi milik orang lain (Step 17)
  declare
    v_uid uuid := auth.uid();
    valid_req jsonb := '[]'::jsonb;
    rejected_list jsonb := '[]'::jsonb;
  begin
    for v_rec in (
      select t.x, t.y, t.c, px.protected_until, px.uid as owner_uid
      from jsonb_to_recordset(p) as t(x int, y int, c smallint)
      left join pixels px on px.x = t.x and px.y = t.y
    ) loop
      if v_rec.protected_until is not null and v_rec.protected_until > now() and (v_rec.owner_uid is distinct from v_uid) then
        rejected_list := rejected_list || jsonb_build_array(jsonb_build_object('x', v_rec.x, 'y', v_rec.y, 'reason', 'protected'));
      else
        valid_req := valid_req || jsonb_build_array(jsonb_build_object('x', v_rec.x, 'y', v_rec.y, 'c', v_rec.c));
      end if;
    end loop;

    if jsonb_array_length(valid_req) = 0 then
      return jsonb_set(get_state(), '{rejected}', rejected_list);
    end if;

    -- Hitung hanya pixel baru (grid yang belum ada di tabel pixels)
    select count(*) into new_count
    from jsonb_to_recordset(valid_req) as t(x int, y int)
    where not exists (select 1 from pixels px where px.x = t.x and px.y = t.y);

    if new_count > 0 and floor(me.stock) < new_count then
      raise exception 'Stok pixel tidak cukup';
    end if;

    insert into pixels(x, y, c, uid, updated_at)
      select t.x, t.y, t.c, v_uid, now() from jsonb_to_recordset(valid_req) as t(x int, y int, c smallint)
    on conflict (x, y) do update set
      c = excluded.c,
      uid = excluded.uid,
      updated_at = now(),
      protected_until = case when pixels.uid = v_uid then null else pixels.protected_until end;

    -- Hanya potong stok untuk pixel baru; grid yang sudah terisi tidak memotong stok
    if new_count > 0 then
      update players set
        stock = stock - new_count,
        day_placed = day_placed + new_count,
        total_placed = total_placed + new_count,
        last_placed_at = now()
      where id = me.id;
    else
      update players set last_placed_at = now() where id = me.id;
    end if;
  end;

  -- Target Bersama / Global Community Goal (Step 12)
  if exists (select 1 from information_schema.tables where table_name = 'global_goal') and coalesce(new_count, 0) > 0 then
    for v_rec in (
      select g.id, g.target, g.reward_boost_min
      from global_goal g
      where now() between g.starts_at and g.ends_at and not g.rewarded
      order by g.id desc limit 1
    ) loop
      update goal_counter gc
      set n = gc.n + new_count
      where gc.goal_id = v_rec.id and gc.shard = floor(random() * 8)::smallint;

      select coalesce(sum(gc.n), 0) into current_goal_n from goal_counter gc where gc.goal_id = v_rec.id;
      if current_goal_n >= v_rec.target then
        update global_goal set rewarded = true where id = v_rec.id;
        update config set global_boost_until = greatest(coalesce(global_boost_until, now()), now()) + (v_rec.reward_boost_min || ' minutes')::interval;
      end if;
    end loop;
  end if;

  -- Deteksi Wilayah Provinsi & Misi Jelajah (Step 13)
  if exists (select 1 from information_schema.tables where table_name = 'regions') then
    with batch_regs as (
      select distinct reg_tbl.id
      from jsonb_to_recordset(p) as t(x int, y int)
      join regions reg_tbl on t.x between reg_tbl.min_x and reg_tbl.max_x and t.y between reg_tbl.min_y and reg_tbl.max_y
    )
    update players set
      regions_today = (
        select coalesce(array_agg(distinct reg), '{}')
        from unnest(coalesce(me.regions_today, '{}') || (select coalesce(array_agg(id), '{}') from batch_regs)) as reg
      ),
      regions_alltime = (
        select coalesce(array_agg(distinct reg), '{}')
        from unnest(coalesce(me.regions_alltime, '{}') || (select coalesce(array_agg(id), '{}') from batch_regs)) as reg
      )
    where id = me.id;
  end if;

  -- Periksa & Berikan Lencana Otomatis (Step 13)
  if exists (select 1 from pg_proc where proname = 'check_and_award_badges') then
    perform check_and_award_badges(me.id);
  end if;

  -- Siarkan Realtime Broadcast per chunk jika realtime.send tersedia
  if exists (select 1 from pg_proc where proname = 'send' and pronamespace = 'realtime'::regnamespace) then
    for v_rec in (
      select
        floor(t.x::numeric / 64)::int as cx,
        floor(t.y::numeric / 64)::int as cy,
        jsonb_agg(jsonb_build_object('x', t.x, 'y', t.y, 'c', t.c)) as p_list
      from jsonb_to_recordset(p) as t(x int, y int, c smallint)
      group by floor(t.x::numeric / 64)::int, floor(t.y::numeric / 64)::int
    ) loop
      perform realtime.send(
        jsonb_build_object('p', v_rec.p_list),
        'pixels',
        'chunk:' || v_rec.cx || '_' || v_rec.cy
      );
    end loop;
  end if;

  return get_state();
end $$;

create or replace function delete_pixels(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  c config;
  n int := jsonb_array_length(p);
  deleted_count int;
  r record;
begin
  select * into c from config;
  if n < 1 or n > coalesce(c.max_batch_size, 20) then raise exception 'Jumlah pixel tidak valid'; end if;
  me := refresh_player();
  if me.banned then raise exception 'Akun Anda diblokir karena melanggar aturan komunitas'; end if;

  with del as (
    delete from pixels where (x, y) in (
      select x, y from jsonb_to_recordset(p) as t(x int, y int)
    )
    returning x, y
  )
  select count(*) into deleted_count from del;

  if deleted_count > 0 then
    update players set stock = least(me.max_stock, stock + deleted_count) where id = me.id;

    if exists (select 1 from pg_proc where proname = 'send' and pronamespace = 'realtime'::regnamespace) then
      for r in (
        select
          floor(x::numeric / 64)::int as cx,
          floor(y::numeric / 64)::int as cy,
          jsonb_agg(jsonb_build_object('x', x, 'y', y, 'del', true)) as p_list
        from jsonb_to_recordset(p) as t(x int, y int)
        group by floor(x::numeric / 64)::int, floor(y::numeric / 64)::int
      ) loop
        perform realtime.send(
          jsonb_build_object('p', r.p_list),
          'pixels',
          'chunk:' || r.cx || '_' || r.cy
        );
      end loop;
    end if;
  end if;

  return get_state();
end $$;

-- Klaim harian: +50 pixel, ditambah 10 per hari beruntun (maks. 7 hari)
create or replace function claim_daily() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me players; s int;
begin
  me := refresh_player();
  if me.banned then raise exception 'Akun Anda diblokir karena melanggar aturan komunitas'; end if;
  if me.last_daily = jkt() then raise exception 'Hadiah harian sudah diklaim'; end if;
  s := case when me.last_daily = jkt() - 1 then me.streak + 1 else 1 end;
  update players set
    streak = s,
    best_streak = greatest(coalesce(best_streak, 0), s),
    last_daily = jkt(),
    stock = stock + 50 + 10 * least(s, 7)
  where id = me.id;
  if exists (select 1 from pg_proc where proname = 'check_and_award_badges') then
    perform check_and_award_badges(me.id);
  end if;
  return get_state();
end $$;


-- ===== TABEL MISI (Single Source of Truth) =====
create table if not exists missions (
  id text primary key,
  kind text not null default 'day_placed',
  need int not null,
  reward_stock int not null default 0,
  reward_boost_min int not null default 0,
  title text not null
);

alter table missions enable row level security;
drop policy if exists "missions_read_all" on missions;
create policy "missions_read_all" on missions for select to public using (true);

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

drop function if exists get_missions() cascade;
create or replace function get_missions() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(m)), '[]'::jsonb)
  from (select * from missions order by need asc) m;
$$;
revoke execute on function get_missions() from public;
grant execute on function get_missions() to anon, authenticated;

-- Misi harian & jelajah (berdasarkan tabel missions)
drop function if exists claim_mission(text) cascade;
create or replace function claim_mission(mid text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  m record;
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

  if exists (select 1 from pg_proc where proname = 'check_and_award_badges') then
    perform check_and_award_badges(me.id);
  end if;

  return get_state();
end $$;

-- ===== Peringkat =====
create index if not exists idx_players_total_placed on players (total_placed desc);
create index if not exists idx_players_day_placed on players (day, day_placed desc);

create or replace function set_nick(n text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  clean text := trim(n);
  me players;
  c config;
begin
  select * into c from config;
  me := refresh_player();
  if me.banned then raise exception 'Akun Anda diblokir karena melanggar aturan komunitas'; end if;

  if clean !~ '^[A-Za-z0-9_ ]{3,16}$' then
    raise exception 'Nama 3-16 karakter: huruf, angka, spasi, atau garis bawah';
  end if;

  if me.last_nick_change is not null and me.last_nick_change > now() - (coalesce(c.nick_change_cooldown_hours, 24) || ' hours')::interval then
    raise exception 'Nama tampilan hanya dapat diganti sekali setiap % jam', coalesce(c.nick_change_cooldown_hours, 24);
  end if;

  update players set nick = clean, last_nick_change = now() where id = auth.uid();
  return get_state();
end $$;

-- kind = 'day' (hari ini, WIB) atau 'all' (sepanjang waktu). Mengembalikan 20 teratas + peringkat sendiri.
create or replace function get_leaderboard(kind text default 'all') returns jsonb
language plpgsql security definer set search_path = public as $$
declare me players; res jsonb; rk int; mine bigint;
begin
  me := refresh_player();
  if kind = 'day' then
    select coalesce(jsonb_agg(r), '[]') into res from (
      select coalesce(nick, 'Anonim') as nick, day_placed as n, id = auth.uid() as me
      from players where day = jkt() and day_placed > 0 order by day_placed desc limit 20) r;
    select count(*) + 1 into rk from players where day = jkt() and day_placed > me.day_placed;
    mine := me.day_placed;
  else
    select coalesce(jsonb_agg(r), '[]') into res from (
      select coalesce(nick, 'Anonim') as nick, total_placed as n, id = auth.uid() as me
      from players where total_placed > 0 order by total_placed desc limit 20) r;
    select count(*) + 1 into rk from players where total_placed > me.total_placed;
    mine := me.total_placed;
  end if;
  return jsonb_build_object('top', res, 'rank', rk, 'n', mine);
end $$;

-- ===== Iklan berhadiah =====
create or replace function start_ad() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me players; c config;
begin
  select * into c from config; me := refresh_player();
  if me.banned then raise exception 'Akun Anda diblokir karena melanggar aturan komunitas'; end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Masuk dengan Google dulu untuk mendapat hadiah iklan';
  end if;
  if me.ads_today >= c.ad_daily_cap then raise exception 'Batas iklan hari ini sudah tercapai'; end if;
  if me.last_ad_at is not null and now() - me.last_ad_at < make_interval(secs => c.ad_cooldown_sec) then
    raise exception 'Tunggu sebentar sebelum iklan berikutnya';
  end if;
  update players set ad_started_at = now() where id = me.id;
  return get_state();
end $$;

create or replace function claim_ad() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me players; c config;
begin
  select * into c from config; me := refresh_player();
  if me.banned then raise exception 'Akun Anda diblokir karena melanggar aturan komunitas'; end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Masuk dengan Google dulu untuk mendapat hadiah iklan';
  end if;
  if me.ad_started_at is null
     or now() - me.ad_started_at < make_interval(secs => c.ad_min_sec)
     or now() - me.ad_started_at > interval '10 minutes' then
    raise exception 'Iklan belum selesai';
  end if;
  if me.ads_today >= c.ad_daily_cap then raise exception 'Batas iklan hari ini sudah tercapai'; end if;
  update players set stock = stock + c.ad_reward, ads_today = ads_today + 1,
    last_ad_at = now(), ad_started_at = null where id = me.id;
  return get_state();
end $$;

-- ===== SISTEM MODERASI & ADMIN (Step 3) =====
create table if not exists roles (
  uid uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('admin', 'moderator')),
  created_at timestamptz default now()
);
alter table roles enable row level security;
drop policy if exists r_roles on roles;
create policy r_roles on roles for select using (uid = auth.uid());

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from roles where uid = auth.uid() and role = 'admin');
$$;

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
drop policy if exists r_reports_admin on reports;
create policy r_reports_admin on reports for all using (is_admin());
drop policy if exists r_reports_user on reports;
create policy r_reports_user on reports for select using (reporter_id = auth.uid());

create table if not exists mod_logs (
  id bigint generated always as identity primary key,
  admin_uid uuid default auth.uid(),
  action text not null,
  target_uid uuid,
  details jsonb,
  created_at timestamptz default now()
);
alter table mod_logs enable row level security;
drop policy if exists r_mod_logs on mod_logs;
create policy r_mod_logs on mod_logs for select using (is_admin());

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

create or replace function admin_delete_rect(x1 int, y1 int, x2 int, y2 int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  min_x int := least(x1, x2);
  max_x int := greatest(x1, x2);
  min_y int := least(y1, y2);
  max_y int := greatest(y1, y2);
  del_count int;
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

create or replace function admin_toggle_ban(p_uid uuid, p_ban boolean, p_reason text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Hanya admin yang dapat menjalankan fungsi ini'; end if;

  update players set banned = p_ban where id = p_uid;

  insert into mod_logs(action, target_uid, details)
  values (case when p_ban then 'ban_player' else 'unban_player' end, p_uid, jsonb_build_object('reason', p_reason));

  return jsonb_build_object('success', true, 'banned', p_ban);
end $$;

create or replace function admin_reset_nick(p_uid uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Hanya admin yang dapat menjalankan fungsi ini'; end if;

  update players set nick = null where id = p_uid;

  insert into mod_logs(action, target_uid, details)
  values ('reset_nick', p_uid, '{}'::jsonb);

  return jsonb_build_object('success', true, 'message', 'Nama berhasil direset');
end $$;

create or replace function admin_resolve_report(p_rep_id bigint, p_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Hanya admin yang dapat menjalankan fungsi ini'; end if;
  if p_status not in ('resolved', 'dismissed') then raise exception 'Status tidak valid'; end if;

  update reports set status = p_status where id = p_rep_id;
  return jsonb_build_object('success', true, 'status', p_status);
end $$;

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

-- ===== OPTIMASI KUOTA & PEMANTAUAN (Step 5) =====
-- get_chunks_compact: Mengembalikan array ringkas [[x,y,c], ...] menghemat 60%+ egress
create or replace function get_chunks_compact(chunks jsonb)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    jsonb_agg(jsonb_build_array(p.x, p.y, p.c)),
    '[]'::jsonb
  )
  from pixels p
  join jsonb_to_recordset(chunks) as req(cx int, cy int)
    on p.cx = req.cx and p.cy = req.cy;
$$;

create or replace function get_system_stats()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_is_adm boolean;
  v_db_bytes bigint;
  v_pixels bigint;
  v_players bigint;
  v_active_today bigint;
  v_reports_pending int;
  v_db_limit_bytes bigint := 500 * 1024 * 1024;
begin
  select is_admin() into v_is_adm;
  if not coalesce(v_is_adm, false) then
    raise exception 'Akses ditolak: Hanya moderator/admin yang dapat melihat statistik sistem';
  end if;

  select pg_database_size(current_database()) into v_db_bytes;
  select count(*) into v_pixels from pixels;
  select count(*) into v_players from players;
  select count(*) into v_active_today from players where day = jkt();
  select count(*) into v_reports_pending from reports where status = 'pending';

  return jsonb_build_object(
    'db_bytes', v_db_bytes,
    'db_size_mb', round((v_db_bytes::numeric / (1024 * 1024)), 2),
    'db_limit_mb', 500,
    'db_usage_pct', round((v_db_bytes::numeric / v_db_limit_bytes) * 100, 1),
    'db_warning', v_db_bytes >= (v_db_limit_bytes * 0.7),
    'pixels_total', v_pixels,
    'players_total', v_players,
    'players_active_today', v_active_today,
    'reports_pending', v_reports_pending,
    'limits', jsonb_build_object(
      'free_db_mb', 500,
      'free_egress_gb', 5,
      'free_realtime_conn', 200,
      'free_realtime_msg_per_sec', 100,
      'warn_threshold_pct', 70
    )
  );
end $$;

-- ===== INFO PIXEL & RIWAYAT PEMBUAT (Step 9) =====
-- get_pixel_info: Mengembalikan info pixel {x, y, c, nick, at} tanpa membocorkan auth.uid (Aturan #12)
create or replace function get_pixel_info(p_x int, p_y int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  c config;
  p players;
  elapsed_ms numeric;
  px_record record;
begin
  select * into c from config;
  select * into p from players where id = v_uid;

  -- Batas laju per pemain
  if p.last_info_at is not null and coalesce(c.info_cooldown_ms, 500) > 0 then
    elapsed_ms := extract(epoch from (now() - p.last_info_at)) * 1000;
    if elapsed_ms < c.info_cooldown_ms then
      raise exception 'Terlalu cepat. Tunggu sebentar sebelum memeriksa pixel lain';
    end if;
  end if;

  update players set last_info_at = now() where id = v_uid;

  select
    px.x,
    px.y,
    px.c,
    px.updated_at,
    coalesce(pl.nick, 'Anonim') as nick
  into px_record
  from pixels px
  left join players pl on pl.id = px.uid
  where px.x = p_x and px.y = p_y;

  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'x', px_record.x,
    'y', px_record.y,
    'c', px_record.c,
    'nick', px_record.nick,
    'at', px_record.updated_at
  );
end $$;

revoke execute on function get_pixel_info(int, int) from public;
grant execute on function get_pixel_info(int, int) to anon, authenticated;

-- ===== PETA PANAS AKTIVITAS / HEATMAP (Step 10) =====
create index if not exists idx_pixels_updated_at on pixels(updated_at);

create table if not exists heat (
  level smallint not null,
  hx int not null,
  hy int not null,
  n int not null check (n > 0),
  primary key (level, hx, hy)
);

create index if not exists idx_heat_level on heat(level);

drop function if exists refresh_heat() cascade;
create or replace function refresh_heat()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_count_l0 int := 0;
  v_count_l1 int := 0;
  v_tot_px bigint := 0;
  v_tot_pl bigint := 0;
  v_today_px bigint := 0;
begin
  truncate table heat;

  -- Level 0 (Zoom 5-9): Agregasi per 500 sel (0.5°)
  insert into heat (level, hx, hy, n)
  select
    0 as level,
    floor(x::numeric / 500)::int as hx,
    floor(y::numeric / 500)::int as hy,
    count(*)::int as n
  from pixels
  where updated_at >= (now() - interval '24 hours')
  group by 1, 2, 3
  having count(*) > 0;
  get diagnostics v_count_l0 = row_count;

  -- Level 1 (Zoom 10-15): Agregasi per 50 sel (0.05°)
  insert into heat (level, hx, hy, n)
  select
    1 as level,
    floor(x::numeric / 50)::int as hx,
    floor(y::numeric / 50)::int as hy,
    count(*)::int as n
  from pixels
  where updated_at >= (now() - interval '24 hours')
  group by 1, 2, 3
  having count(*) > 0;
  get diagnostics v_count_l1 = row_count;

  -- Perbarui statistik publik jika tabel stats ada (Step 15)
  if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'stats') then
    select count(*) into v_tot_px from pixels;
    select count(*) into v_tot_pl from players;
    select count(*) into v_today_px from pixels where updated_at >= (now() at time zone 'Asia/Jakarta')::date;

    insert into stats (id, total_pixels, total_players, today_pixels, updated_at)
    values (1, v_tot_px, v_tot_pl, v_today_px, now())
    on conflict (id) do update set
      total_pixels = excluded.total_pixels,
      total_players = excluded.total_players,
      today_pixels = excluded.today_pixels,
      updated_at = excluded.updated_at;
  end if;

  -- Perbarui peringkat tim provinsi jika fungsi refresh_team_board ada (Step 18)
  if exists (select 1 from pg_proc where proname = 'refresh_team_board' and pronamespace = 'public'::regnamespace) then
    perform refresh_team_board();
  end if;

  return jsonb_build_object(
    'success', true,
    'level_0_cells', v_count_l0,
    'level_1_cells', v_count_l1,
    'total_pixels', v_tot_px,
    'total_players', v_tot_pl,
    'today_pixels', v_today_px,
    'refreshed_at', now()
  );
end $$;

create or replace function get_heat(p_level smallint)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    jsonb_agg(jsonb_build_array(hx, hy, n)),
    '[]'::jsonb
  )
  from heat
  where level = p_level;
$$;

revoke execute on function refresh_heat() from public;
grant execute on function refresh_heat() to authenticated;

revoke execute on function get_heat(smallint) from public;
grant execute on function get_heat(smallint) to anon, authenticated;

-- ===== EVENT & TARGET BERSAMA (Step 12) =====
alter table config add column if not exists event_max_mult numeric default 4;
alter table config add column if not exists global_boost_until timestamptz;

create table if not exists events (
  id serial primary key,
  name text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  refill_mult numeric not null default 1,
  banner text,
  constraint event_window_check check (ends_at > starts_at)
);

create index if not exists idx_events_window on events(starts_at, ends_at);

create table if not exists global_goal (
  id serial primary key,
  name text not null,
  target bigint not null check (target > 0),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reward_boost_min int not null default 60,
  rewarded bool not null default false,
  constraint goal_window_check check (ends_at > starts_at)
);

create index if not exists idx_global_goal_window on global_goal(starts_at, ends_at);

create table if not exists goal_counter (
  goal_id int not null references global_goal(id) on delete cascade,
  shard smallint not null check (shard between 0 and 7),
  n bigint not null default 0,
  primary key (goal_id, shard)
);

create or replace function init_goal_shards()
returns trigger language plpgsql as $$
begin
  insert into goal_counter(goal_id, shard, n)
  select new.id, s, 0
  from generate_series(0, 7) s;
  return new;
end $$;

drop trigger if exists trg_init_goal_shards on global_goal;
create trigger trg_init_goal_shards
after insert on global_goal
for each row execute function init_goal_shards();

insert into events (name, starts_at, ends_at, refill_mult, banner)
values (
  'Pekan Nusantara',
  now() - interval '1 hour',
  now() + interval '7 days',
  2,
  'Event Pekan Nusantara: Pengisian stok 2x lebih cepat untuk semua pemain!'
)
on conflict do nothing;

insert into global_goal (name, target, starts_at, ends_at, reward_boost_min)
values (
  'Target Bersama: 10.000 Pixel',
  10000,
  now() - interval '1 hour',
  now() + interval '7 days',
  60
)
on conflict do nothing;

create or replace function get_event_state()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c config;
  ev record;
  gg record;
  total_progress bigint := 0;
begin
  select * into c from config;

  select * into ev
  from events
  where now() between starts_at and ends_at
  order by id desc
  limit 1;

  select * into gg
  from global_goal
  where now() between starts_at and ends_at
  order by id desc
  limit 1;

  if gg.id is not null then
    select coalesce(sum(n), 0) into total_progress
    from goal_counter
    where goal_id = gg.id;
  end if;

  return jsonb_build_object(
    'event', case when ev.id is not null then jsonb_build_object(
      'id', ev.id,
      'name', ev.name,
      'refill_mult', least(coalesce(ev.refill_mult, 1), coalesce(c.event_max_mult, 4)),
      'banner', ev.banner,
      'ends_at', ev.ends_at
    ) else null end,
    'goal', case when gg.id is not null then jsonb_build_object(
      'id', gg.id,
      'name', gg.name,
      'target', gg.target,
      'current', total_progress,
      'pct', round(least(100, (total_progress::numeric / gg.target) * 100), 1),
      'rewarded', gg.rewarded,
      'reward_boost_min', gg.reward_boost_min,
      'ends_at', gg.ends_at
    ) else null end,
    'global_boost_until', c.global_boost_until,
    'global_boost_active', (c.global_boost_until is not null and c.global_boost_until > now())
  );
end $$;

revoke execute on function get_event_state() from public;
grant execute on function get_event_state() to anon, authenticated;

-- ==============================================================================
-- Step 13: Misi Jelajah, Wilayah Provinsi, Lencana & Profil
-- ==============================================================================

-- 1. Wilayah / Kotak Kasar 38 Provinsi Indonesia (aturan #10)
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

-- 4. Profil Pemain RPC (get_player_profile)
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

revoke execute on function get_player_profile(uuid) from public;
grant execute on function get_player_profile(uuid) to anon, authenticated;

-- ===== STATISTIK PUBLIK & TABEL STATS (Step 15) =====
create table if not exists stats (
  id int primary key default 1 check (id = 1),
  total_pixels bigint not null default 0,
  total_players bigint not null default 0,
  today_pixels bigint not null default 0,
  updated_at timestamptz not null default now()
);

insert into stats (id, total_pixels, total_players, today_pixels, updated_at)
values (
  1,
  coalesce((select count(*) from pixels), 0),
  coalesce((select count(*) from players), 0),
  coalesce((select count(*) from pixels where updated_at >= (now() at time zone 'Asia/Jakarta')::date), 0),
  now()
)
on conflict (id) do update set
  total_pixels = excluded.total_pixels,
  total_players = excluded.total_players,
  today_pixels = excluded.today_pixels,
  updated_at = excluded.updated_at;

alter table stats enable row level security;
drop policy if exists p_stats_read on stats;
create policy p_stats_read on stats for select using (true);

-- Inisialisasi penyegaran heatmap dan tabel stats
select refresh_heat();

create or replace function get_public_stats()
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'total_pixels', coalesce(total_pixels, 0),
    'total_players', coalesce(total_players, 0),
    'today_pixels', coalesce(today_pixels, 0),
    'updated_at', updated_at
  )
  from stats
  where id = 1;
$$;

revoke execute on function get_public_stats() from public;
grant execute on function get_public_stats() to anon, authenticated;

-- ===== TIME-LAPSE & SNAPSHOT CHUNK (Step 16) =====
create table if not exists snapshots (
  day date not null,
  cx int not null,
  cy int not null,
  data bytea not null,
  primary key (day, cx, cy)
);

create index if not exists idx_snapshots_day on snapshots(day);

alter table snapshots enable row level security;
drop policy if exists p_snapshots_read on snapshots;
create policy p_snapshots_read on snapshots for select using (true);

create or replace function build_chunk_snapshot(p_cx int, p_cy int)
returns bytea
language plpgsql stable security definer set search_path = public as $$
declare
  v_chars text[];
  v_rec record;
  v_rx int;
  v_ry int;
  v_idx int;
  v_hex text;
begin
  v_chars := array_fill('0'::text, array[4096]);

  for v_rec in
    select x, y, c
    from pixels
    where cx = p_cx and cy = p_cy
  loop
    v_rx := (v_rec.x - p_cx * 64);
    v_ry := (v_rec.y - p_cy * 64);
    if v_rx >= 0 and v_rx < 64 and v_ry >= 0 and v_ry < 64 then
      v_idx := (v_ry * 64 + v_rx) + 1;
      v_chars[v_idx] := to_hex(least(15, greatest(1, v_rec.c + 1)));
    end if;
  end loop;

  v_hex := array_to_string(v_chars, '');
  return decode(v_hex, 'hex');
end $$;

create or replace function create_daily_snapshots(
  p_day date default (now() at time zone 'Asia/Jakarta')::date - interval '1 day',
  p_test_max_bytes bigint default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_db_bytes bigint;
  v_max_bytes bigint := coalesce(p_test_max_bytes, (500 * 1024 * 1024 * 0.70)::bigint);
  v_rec record;
  v_count int := 0;
  v_deleted int := 0;
  v_snap_bytes bytea;
begin
  select pg_database_size(current_database()) into v_db_bytes;
  if v_db_bytes >= v_max_bytes then
    insert into mod_logs (action, detail)
    values (
      'snapshot_aborted',
      'Pembuatan snapshot dibatalkan: Ukuran DB (' || (v_db_bytes / (1024 * 1024)) || ' MB) melampaui ambang batas 70% (' || (v_max_bytes / (1024 * 1024)) || ' MB)'
    );
    return jsonb_build_object(
      'success', false,
      'error', 'quota_exceeded',
      'db_size_mb', round((v_db_bytes::numeric / (1024 * 1024)), 2),
      'limit_mb', round((v_max_bytes::numeric / (1024 * 1024)), 2)
    );
  end if;

  delete from snapshots
  where day < (p_day - interval '30 days');
  get diagnostics v_deleted = row_count;

  for v_rec in
    select distinct cx, cy
    from pixels
    where updated_at >= p_day and updated_at < (p_day + interval '1 day')
  loop
    v_snap_bytes := build_chunk_snapshot(v_rec.cx, v_rec.cy);
    insert into snapshots (day, cx, cy, data)
    values (p_day, v_rec.cx, v_rec.cy, v_snap_bytes)
    on conflict (day, cx, cy) do update set
      data = excluded.data;
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object(
    'success', true,
    'day', p_day,
    'chunks_snapshotted', v_count,
    'old_snapshots_deleted', v_deleted,
    'db_size_mb', round((v_db_bytes::numeric / (1024 * 1024)), 2)
  );
end $$;

create or replace function get_snapshots(
  p_day_from date,
  p_day_to date,
  chunks jsonb
)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_chunk_count int;
  v_day_diff int;
  v_result jsonb;
begin
  if p_day_to < p_day_from then
    raise exception 'Tanggal akhir tidak boleh lebih awal dari tanggal awal';
  end if;

  v_day_diff := (p_day_to - p_day_from);
  if v_day_diff > 14 then
    raise exception 'Rentang waktu maksimal time-lapse adalah 14 hari';
  end if;

  v_chunk_count := jsonb_array_length(chunks);
  if v_chunk_count > 50 then
    raise exception 'Maksimal 50 chunk per pemutaran time-lapse';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_array(
        to_char(s.day, 'YYYY-MM-DD'),
        s.cx,
        s.cy,
        encode(s.data, 'hex')
      )
    ),
    '[]'::jsonb
  )
  into v_result
  from snapshots s
  join jsonb_to_recordset(chunks) as req(cx int, cy int)
    on s.cx = req.cx and s.cy = req.cy
  where s.day between p_day_from and p_day_to;

  return v_result;
end $$;

revoke execute on function create_daily_snapshots(date, bigint) from public;
grant execute on function create_daily_snapshots(date, bigint) to authenticated;

revoke execute on function get_snapshots(date, date, jsonb) from public;
grant execute on function get_snapshots(date, date, jsonb) to anon, authenticated;

-- ===== PIXEL TERLINDUNGI / PROTECTED PIXELS (Step 17) =====
alter table pixels add column if not exists protected_until timestamptz;
create index if not exists idx_pixels_protected on pixels(protected_until)
where protected_until is not null;

alter table config add column if not exists protect_cost int default 5;
alter table config add column if not exists protect_duration_hours int default 24;
alter table config add column if not exists max_protected_per_player int default 25;

create or replace function protect_pixels(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  me players;
  c config;
  n int := jsonb_array_length(p);
  v_cost int;
  v_active_count int;
  v_duration interval;
  v_rec record;
begin
  if v_uid is null then
    raise exception 'Harus masuk untuk melindungi pixel';
  end if;

  select * into c from config;
  me := refresh_player();
  if me.banned then
    raise exception 'Akun Anda diblokir karena melanggar aturan komunitas';
  end if;

  if n < 1 or n > 25 then
    raise exception 'Jumlah pixel yang dilindungi maksimal 25 per permintaan';
  end if;

  if exists (select 1 from jsonb_to_recordset(p) as t(x int, y int)
             where x not between c.min_x and c.max_x or y not between c.min_y and c.max_y) then
    raise exception 'Koordinat di luar batas kanvas Indonesia';
  end if;

  select count(*) into v_active_count
  from pixels
  where uid = v_uid and protected_until > now();

  if (v_active_count + n) > coalesce(c.max_protected_per_player, 25) then
    raise exception 'Batas maksimal pixel terlindungi aktif adalah % (saat ini aktif: %)',
      coalesce(c.max_protected_per_player, 25), v_active_count;
  end if;

  for v_rec in select x, y from jsonb_to_recordset(p) as t(x int, y int) loop
    if not exists (select 1 from pixels where x = v_rec.x and y = v_rec.y and uid = v_uid) then
      raise exception 'Hanya dapat melindungi pixel yang Anda buat sendiri di titik (%, %)', v_rec.x, v_rec.y;
    end if;
  end loop;

  v_cost := n * coalesce(c.protect_cost, 5);
  if floor(me.stock) < v_cost then
    raise exception 'Stok tidak mencukupi untuk proteksi (% dibutuhkan, stok saat ini %)', v_cost, floor(me.stock);
  end if;

  v_duration := (coalesce(c.protect_duration_hours, 24) || ' hours')::interval;

  update pixels px
  set protected_until = now() + v_duration
  from jsonb_to_recordset(p) as req(x int, y int)
  where px.x = req.x and px.y = req.y and px.uid = v_uid;

  update players set
    stock = stock - v_cost
  where id = v_uid;

  return get_state();
end $$;

create or replace function get_protected_pixels(chunks jsonb)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_array(p.x, p.y, extract(epoch from p.protected_until)::bigint)
    ),
    '[]'::jsonb
  )
  from pixels p
  join jsonb_to_recordset(chunks) as req(cx int, cy int)
    on p.cx = req.cx and p.cy = req.cy
  where p.protected_until is not null and p.protected_until > now();
$$;

revoke execute on function protect_pixels(jsonb) from public;
grant execute on function protect_pixels(jsonb) to authenticated;

revoke execute on function get_protected_pixels(jsonb) from public;
grant execute on function get_protected_pixels(jsonb) to anon, authenticated;

-- ==============================================================================
-- Migrasi 013: Peringkat Tim Provinsi (Step 18)
-- ==============================================================================

-- 1. Konfigurasi cooldown penggantian tim (7 hari)
alter table config add column if not exists team_change_cooldown_days int default 7;
update config set team_change_cooldown_days = 7 where team_change_cooldown_days is null;

-- 2. Kolom team_id dan last_team_change di tabel players
alter table players add column if not exists team_id int references regions(id) on delete set null;
alter table players add column if not exists last_team_change timestamptz;
create index if not exists idx_players_team_id on players(team_id);

-- 3. Tabel agregat peringkat tim provinsi (team_board)
create table if not exists team_board (
  team_id int primary key references regions(id) on delete cascade,
  team_name text not null,
  total_pixels bigint not null default 0,
  day_pixels bigint not null default 0,
  active_players int not null default 0,
  updated_at timestamptz not null default now()
);

alter table team_board enable row level security;
drop policy if exists "team_board_read_all" on team_board;
create policy "team_board_read_all" on team_board for select to public using (true);

-- 4. Fungsi penyegaran agregat peringkat tim
create or replace function refresh_team_board() returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into team_board (team_id, team_name, total_pixels, day_pixels, active_players, updated_at)
  select
    r.id as team_id,
    r.name as team_name,
    coalesce(sum(p.total_placed), 0) as total_pixels,
    coalesce(sum(case when p.day = jkt() then p.day_placed else 0 end), 0) as day_pixels,
    count(p.id) filter (where coalesce(p.total_placed, 0) > 0) as active_players,
    now() as updated_at
  from regions r
  left join players p on p.team_id = r.id
  group by r.id, r.name
  on conflict (team_id) do update set
    team_name = excluded.team_name,
    total_pixels = excluded.total_pixels,
    day_pixels = excluded.day_pixels,
    active_players = excluded.active_players,
    updated_at = excluded.updated_at;
end $$;

-- Inisialisasi awal data agregat tim
select refresh_team_board();

-- Segarkan seluruh agregasi (heatmap, stats publik, dan tim papan peringkat)
select refresh_heat();

-- 5. RPC untuk mengambil daftar provinsi (38 provinsi)
create or replace function get_regions() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object('id', id, 'name', name)
      order by name asc
    ),
    '[]'::jsonb
  )
  from regions;
$$;

revoke execute on function get_regions() from public;
grant execute on function get_regions() to anon, authenticated;

-- 6. RPC untuk memilih atau mengganti tim provinsi
create or replace function set_team(p_team_id int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  c config;
  reg_name text;
  cooldown_days int;
begin
  me := refresh_player();
  if me.banned then
    raise exception 'Akun Anda diblokir karena melanggar aturan komunitas';
  end if;

  select * into c from config;
  cooldown_days := coalesce(c.team_change_cooldown_days, 7);

  -- Validasi keberadaan wilayah tim
  select name into reg_name from regions where id = p_team_id;
  if reg_name is null then
    raise exception 'Provinsi tim tidak valid';
  end if;

  -- Validasi jeda waktu penggantian tim (cooldown 7 hari)
  if me.last_team_change is not null and me.last_team_change > now() - (cooldown_days || ' days')::interval then
    raise exception 'Tim provinsi hanya dapat diubah sekali setiap % hari', cooldown_days;
  end if;

  update players
  set team_id = p_team_id,
      last_team_change = now()
  where id = me.id;

  -- Segarkan peringkat tim segera
  perform refresh_team_board();

  return jsonb_build_object(
    'status', 'ok',
    'team_id', p_team_id,
    'team_name', reg_name,
    'last_team_change', now()
  );
end $$;

revoke execute on function set_team(int) from public;
grant execute on function set_team(int) to authenticated;

-- 7. RPC untuk membaca leaderboard tim provinsi dari tabel agregat team_board
create or replace function get_team_board() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  res jsonb;
  my_team jsonb := null;
  c config;
  cooldown_days int;
  can_change bool := true;
  next_change timestamptz := null;
begin
  me := refresh_player();
  select * into c from config;
  cooldown_days := coalesce(c.team_change_cooldown_days, 7);

  if me.last_team_change is not null then
    next_change := me.last_team_change + (cooldown_days || ' days')::interval;
    if next_change > now() then
      can_change := false;
    end if;
  end if;

  select coalesce(jsonb_agg(r), '[]'::jsonb) into res from (
    select
      tb.team_id,
      tb.team_name,
      tb.total_pixels as n,
      tb.day_pixels,
      tb.active_players,
      (me.team_id is not null and tb.team_id = me.team_id) as my_team
    from team_board tb
    order by tb.total_pixels desc, tb.team_name asc
  ) r;

  if me.team_id is not null then
    select jsonb_build_object(
      'team_id', tb.team_id,
      'team_name', tb.team_name,
      'n', tb.total_pixels,
      'day_pixels', tb.day_pixels,
      'active_players', tb.active_players,
      'rank', (select count(*) + 1 from team_board where total_pixels > tb.total_pixels)
    ) into my_team
    from team_board tb
    where tb.team_id = me.team_id;
  end if;

  return jsonb_build_object(
    'teams', res,
    'my_team', my_team,
    'player_team_id', me.team_id,
    'can_change_team', can_change,
    'next_change_at', next_change,
    'cooldown_days', cooldown_days
  );
end $$;

revoke execute on function get_team_board() from public;
grant execute on function get_team_board() to anon, authenticated;

-- 8. Pembaruan fungsi get_player_profile dengan informasi tim provinsi
create or replace function get_player_profile(p_uid uuid default auth.uid())
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  p players;
  badges_json jsonb;
  team_info record;
begin
  select * into p from players where id = p_uid;
  if not found then
    return jsonb_build_object('error', 'Pemain tidak ditemukan');
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'badge', pb.badge,
        'at', pb.at,
        'name', b.name,
        'description', b.description
      ) order by pb.at asc
    ),
    '[]'::jsonb
  ) into badges_json
  from player_badges pb
  join badges b on pb.badge = b.id
  where pb.uid = p_uid;

  select id, name into team_info from regions where id = p.team_id;

  return jsonb_build_object(
    'nick', coalesce(p.nick, 'Anonim'),
    'trust_level', coalesce(p.trust_level, 1),
    'total_placed', coalesce(p.total_placed, 0),
    'day_placed', coalesce(p.day_placed, 0),
    'streak', coalesce(p.streak, 0),
    'best_streak', coalesce(p.best_streak, coalesce(p.streak, 0)),
    'regions_today_count', coalesce(array_length(p.regions_today, 1), 0),
    'regions_alltime_count', coalesce(array_length(p.regions_alltime, 1), 0),
    'team_id', p.team_id,
    'team_name', team_info.name,
    'last_team_change', p.last_team_change,
    'badges', badges_json
  );
end $$;

revoke execute on function get_player_profile(uuid) from public;
grant execute on function get_player_profile(uuid) to authenticated, anon;

-- ==============================================================================
-- Migrasi 014: Kode Undangan (Step 19)
-- ==============================================================================

-- 1. Konfigurasi hadiah & batas undangan
alter table config add column if not exists invite_reward int default 100;
alter table config add column if not exists invite_max_claimed int default 10;
alter table config add column if not exists invite_min_placed int default 100;

update config set invite_reward = 100 where invite_reward is null;
update config set invite_max_claimed = 10 where invite_max_claimed is null;
update config set invite_min_placed = 100 where invite_min_placed is null;

-- 2. Tabel invites
create table if not exists invites (
  code text primary key,
  owner uuid not null references auth.users(id) on delete cascade,
  used_by uuid unique references auth.users(id) on delete set null,
  used_at timestamptz,
  rewarded bool not null default false,
  created_at timestamptz not null default now()
);

create index if not exists idx_invites_owner on invites(owner);
create index if not exists idx_invites_used_by on invites(used_by);

alter table invites enable row level security;
drop policy if exists "invites_read_policy" on invites;
create policy "invites_read_policy" on invites
  for select to authenticated
  using (owner = auth.uid() or used_by = auth.uid());

-- 3. RPC untuk melihat status undangan pemain
create or replace function get_my_invites() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  is_anon bool;
  c config;
  res jsonb;
  my_used record;
  rewarded_cnt int;
begin
  if auth.uid() is null then
    return jsonb_build_object('error', 'Belum login');
  end if;

  is_anon := coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false);
  select * into c from config;

  select count(*) into rewarded_cnt
  from invites
  where owner = auth.uid() and rewarded;

  select coalesce(jsonb_agg(r), '[]'::jsonb) into res from (
    select
      i.code,
      i.rewarded,
      i.used_at,
      case when i.used_by is not null then true else false end as is_used,
      coalesce(p.nick, 'Anonim') as friend_nick,
      coalesce(p.total_placed, 0) as friend_total_placed,
      coalesce(c.invite_min_placed, 100) as min_placed_needed,
      (coalesce(p.total_placed, 0) >= coalesce(c.invite_min_placed, 100) and not i.rewarded and i.used_by is not null) as can_claim
    from invites i
    left join players p on i.used_by = p.id
    where i.owner = auth.uid()
    order by i.created_at desc
  ) r;

  select code, used_at into my_used
  from invites
  where used_by = auth.uid();

  return jsonb_build_object(
    'is_anonymous', is_anon,
    'rewarded_count', rewarded_cnt,
    'max_claimed', coalesce(c.invite_max_claimed, 10),
    'reward_stock', coalesce(c.invite_reward, 100),
    'min_placed', coalesce(c.invite_min_placed, 100),
    'has_used_code', (my_used.code is not null),
    'used_code', my_used.code,
    'invites', res
  );
end $$;

revoke execute on function get_my_invites() from public;
grant execute on function get_my_invites() to authenticated;

-- 4. RPC untuk membuat kode undangan baru (8 karakter)
create or replace function create_invite_code() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  c config;
  active_count int;
  rewarded_count int;
  new_code text;
begin
  me := refresh_player();
  if me.banned then
    raise exception 'Akun Anda diblokir karena melanggar aturan komunitas';
  end if;

  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Masuk dengan Google atau Email terlebih dahulu untuk membuat kode undangan';
  end if;

  select * into c from config;

  select count(*) into active_count from invites where owner = me.id and (not rewarded);
  select count(*) into rewarded_count from invites where owner = me.id and rewarded;

  if rewarded_count >= coalesce(c.invite_max_claimed, 10) then
    raise exception 'Batas maksimal % hadiah undangan telah tercapai', coalesce(c.invite_max_claimed, 10);
  end if;

  if active_count >= coalesce(c.invite_max_claimed, 10) then
    raise exception 'Anda memiliki % kode aktif yang belum selesai. Bagikan kode tersebut terlebih dahulu.', active_count;
  end if;

  -- Buat kode acak 8 karakter unik
  loop
    new_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from invites where code = new_code);
  end loop;

  insert into invites(code, owner)
  values (new_code, me.id);

  return get_my_invites();
end $$;

revoke execute on function create_invite_code() from public;
grant execute on function create_invite_code() to authenticated;

-- 5. RPC untuk menggunakan kode undangan pemain lain
create or replace function use_invite_code(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  inv invites;
  c config;
  clean_code text := upper(trim(p_code));
begin
  me := refresh_player();
  if me.banned then
    raise exception 'Akun Anda diblokir karena melanggar aturan komunitas';
  end if;

  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Masuk dengan Google atau Email terlebih dahulu untuk menggunakan kode undangan';
  end if;

  if clean_code is null or length(clean_code) < 6 then
    raise exception 'Kode undangan tidak valid';
  end if;

  -- Periksa apakah pemain sudah pernah memakai kode
  if exists (select 1 from invites where used_by = me.id) then
    raise exception 'Akun Anda sudah pernah menggunakan kode undangan';
  end if;

  select * into inv from invites where code = clean_code;
  if not found then
    raise exception 'Kode undangan tidak ditemukan';
  end if;

  if inv.owner = me.id then
    raise exception 'Tidak dapat menggunakan kode undangan milik sendiri';
  end if;

  if inv.used_by is not null then
    raise exception 'Kode undangan ini sudah digunakan oleh pemain lain';
  end if;

  update invites
  set used_by = me.id,
      used_at = now()
  where code = clean_code;

  -- Hadiah sambutan untuk pemain baru (+25 stok instan)
  update players
  set stock = least(max_stock, stock + 25)
  where id = me.id;

  return jsonb_build_object(
    'status', 'ok',
    'code', clean_code,
    'bonus_stock', 25,
    'message', 'Kode undangan berhasil digunakan! Anda mendapatkan +25 stok pixel.'
  );
end $$;

revoke execute on function use_invite_code(text) from public;
grant execute on function use_invite_code(text) to authenticated;

-- 6. RPC untuk mengklaim hadiah undangan bagi pemilik kode
create or replace function claim_invite_reward(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  inv invites;
  referee players;
  c config;
  rewarded_count int;
  clean_code text := upper(trim(p_code));
begin
  me := refresh_player();
  if me.banned then
    raise exception 'Akun Anda diblokir karena melanggar aturan komunitas';
  end if;

  select * into inv from invites where code = clean_code and owner = me.id;
  if not found then
    raise exception 'Kode undangan tidak ditemukan atau bukan milik Anda';
  end if;

  if inv.rewarded then
    raise exception 'Hadiah untuk kode undangan ini sudah diklaim';
  end if;

  if inv.used_by is null then
    raise exception 'Kode undangan ini belum digunakan oleh siapa pun';
  end if;

  select * into referee from players where id = inv.used_by;
  select * into c from config;

  if coalesce(referee.total_placed, 0) < coalesce(c.invite_min_placed, 100) then
    raise exception 'Teman Anda baru menempatkan % pixel (dibutuhkan minimal % pixel untuk mengklaim hadiah)',
      coalesce(referee.total_placed, 0), coalesce(c.invite_min_placed, 100);
  end if;

  select count(*) into rewarded_count from invites where owner = me.id and rewarded;
  if rewarded_count >= coalesce(c.invite_max_claimed, 10) then
    raise exception 'Batas maksimal % hadiah undangan berhasil telah tercapai', coalesce(c.invite_max_claimed, 10);
  end if;

  -- Beri hadiah ke pemilik kode
  update invites set rewarded = true where code = clean_code;
  update players set stock = least(max_stock, stock + coalesce(c.invite_reward, 100)) where id = me.id;

  return jsonb_build_object(
    'status', 'ok',
    'code', clean_code,
    'reward_stock', coalesce(c.invite_reward, 100),
    'state', get_state()
  );
end $$;

revoke execute on function claim_invite_reward(text) from public;
grant execute on function claim_invite_reward(text) to authenticated;








