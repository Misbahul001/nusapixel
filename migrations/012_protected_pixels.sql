-- ====================================================================
-- MIGRATION 012: PIXEL TERLINDUNGI / PROTECTED PIXELS (Step 17)
-- ====================================================================
-- Parameter Keseimbangan (Disetujui Pemilik):
-- 1. Biaya stok: 5 stok per pixel (protect_cost)
-- 2. Durasi perlindungan: 24 jam (protect_duration_hours)
-- 3. Batas maksimal per pemain: 25 pixel terlindungi aktif (max_protected_per_player)
-- 4. Pemilik boleh menimpa pixel miliknya sendiri tanpa menunggu durasi habis
-- 5. Moderator/admin berhak menghapus pixel terlindungi
-- ====================================================================

-- 1. Kolom protected_until dan indeks parsial
alter table pixels add column if not exists protected_until timestamptz;
create index if not exists idx_pixels_protected on pixels(protected_until)
where protected_until is not null;

-- 2. Konfigurasi di tabel config
alter table config add column if not exists protect_cost int default 5;
alter table config add column if not exists protect_duration_hours int default 24;
alter table config add column if not exists max_protected_per_player int default 25;

-- 3. Fungsi proteksi pixel: protect_pixels(p jsonb)
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

  -- Cek batas wilayah
  if exists (select 1 from jsonb_to_recordset(p) as t(x int, y int)
             where x not between c.min_x and c.max_x or y not between c.min_y and c.max_y) then
    raise exception 'Koordinat di luar batas kanvas Indonesia';
  end if;

  -- Hitung pixel aktif terlindungi yang dimiliki pemain saat ini
  select count(*) into v_active_count
  from pixels
  where uid = v_uid and protected_until > now();

  if (v_active_count + n) > coalesce(c.max_protected_per_player, 25) then
    raise exception 'Batas maksimal pixel terlindungi aktif adalah % (saat ini aktif: %)',
      coalesce(c.max_protected_per_player, 25), v_active_count;
  end if;

  -- Pastikan pemain adalah pemilik pixel yang ingin dilindungi
  for v_rec in select x, y from jsonb_to_recordset(p) as t(x int, y int) loop
    if not exists (select 1 from pixels where x = v_rec.x and y = v_rec.y and uid = v_uid) then
      raise exception 'Hanya dapat melindungi pixel yang Anda buat sendiri di titik (%, %)', v_rec.x, v_rec.y;
    end if;
  end loop;

  -- Hitung biaya stok
  v_cost := n * coalesce(c.protect_cost, 5);
  if floor(me.stock) < v_cost then
    raise exception 'Stok tidak mencukupi untuk proteksi (% dibutuhkan, stok saat ini %)', v_cost, floor(me.stock);
  end if;

  v_duration := (coalesce(c.protect_duration_hours, 24) || ' hours')::interval;

  -- Terapkan masa proteksi
  update pixels px
  set protected_until = now() + v_duration
  from jsonb_to_recordset(p) as req(x int, y int)
  where px.x = req.x and px.y = req.y and px.uid = v_uid;

  -- Potong stok pemain
  update players set
    stock = stock - v_cost
  where id = v_uid;

  return get_state();
end $$;

-- 4. Perbarui place_pixels untuk menghormati pixel terlindungi milik orang lain
create or replace function place_pixels(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  me players;
  c config;
  n int := jsonb_array_length(p);
  new_count int := 0;
  elapsed_sec numeric;
  min_interval_sec numeric;
  current_goal_n bigint;
  r record;
  rejected_list jsonb := '[]'::jsonb;
  valid_req jsonb := '[]'::jsonb;
begin
  select * into c from config;

  if n < 1 or n > coalesce(c.max_batch_size, 20) then
    raise exception 'Ukuran batch tidak valid (maksimal %)', coalesce(c.max_batch_size, 20);
  end if;

  if exists (select 1 from jsonb_to_recordset(p) as t(x int, y int)
             where x not between c.min_x and c.max_x or y not between c.min_y and c.max_y) then
    raise exception 'Kanvas hanya mencakup wilayah Indonesia';
  end if;

  me := refresh_player();
  if me.banned then raise exception 'Akun Anda diblokir karena melanggar aturan komunitas'; end if;

  if me.last_placed_at is not null and coalesce(c.rate_limit_px_per_sec, 5) > 0 then
    elapsed_sec := extract(epoch from (now() - me.last_placed_at));
    min_interval_sec := (n::numeric / c.rate_limit_px_per_sec) * 0.8;
    if elapsed_sec < min_interval_sec then
      raise exception 'Terlalu cepat. Kecepatan maksimal adalah % pixel per detik', c.rate_limit_px_per_sec;
    end if;
  end if;

  -- Filter: pisahkan pixel yang terlindungi milik orang lain (Aturan Step 17)
  for r in (
    select t.x, t.y, t.c, px.protected_until, px.uid as owner_uid
    from jsonb_to_recordset(p) as t(x int, y int, c smallint)
    left join pixels px on px.x = t.x and px.y = t.y
  ) loop
    if r.protected_until is not null and r.protected_until > now() and (r.owner_uid is distinct from v_uid) then
      rejected_list := rejected_list || jsonb_build_array(jsonb_build_object('x', r.x, 'y', r.y, 'reason', 'protected'));
    else
      valid_req := valid_req || jsonb_build_array(jsonb_build_object('x', r.x, 'y', r.y, 'c', r.c));
    end if;
  end loop;

  -- Jika seluruh pixel dalam batch terlindungi, kembalikan status tanpa memotong stok
  if jsonb_array_length(valid_req) = 0 then
    return jsonb_set(get_state(), '{rejected}', rejected_list);
  end if;

  -- Hitung pixel baru di antara permintaan yang valid
  select count(*) into new_count
  from jsonb_to_recordset(valid_req) as t(x int, y int)
  where not exists (select 1 from pixels px where px.x = t.x and px.y = t.y);

  if new_count > 0 and floor(me.stock) < new_count then
    raise exception 'Stok pixel tidak cukup';
  end if;

  insert into pixels(x, y, c, uid, updated_at)
  select x, y, c, v_uid, now()
  from jsonb_to_recordset(valid_req) as t(x int, y int, c smallint)
  on conflict (x, y) do update set
    c = excluded.c,
    uid = excluded.uid,
    updated_at = now(),
    -- Reset proteksi jika ditimpa oleh pemiliknya sendiri
    protected_until = case when pixels.uid = v_uid then null else pixels.protected_until end;

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

  -- Target Komunitas (Step 12)
  if exists (select 1 from information_schema.tables where table_name = 'global_goal') then
    for r in (
      select id, target, reward_boost_min
      from global_goal
      where now() between starts_at and ends_at and not rewarded
      order by id desc limit 1
    ) loop
      update goal_counter
      set n = n + 1
      where goal_id = r.id and shard = floor(random() * 8)::smallint;

      select coalesce(sum(n), 0) into current_goal_n from goal_counter where goal_id = r.id;
      if current_goal_n >= r.target then
        update global_goal set rewarded = true where id = r.id;
        update config set global_boost_until = greatest(coalesce(global_boost_until, now()), now()) + (r.reward_boost_min || ' minutes')::interval;
      end if;
    end loop;
  end if;

  -- Pantau Wilayah & Lencana (Step 13)
  if exists (select 1 from information_schema.tables where table_name = 'regions') then
    perform track_regions_and_badges(me.id, valid_req);
  end if;

  if jsonb_array_length(rejected_list) > 0 then
    return jsonb_set(get_state(), '{rejected}', rejected_list);
  end if;

  return get_state();
end $$;

-- 5. RPC get_protected_pixels: Mengembalikan koordinat pixel terlindungi aktif di area yang tampak
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

-- 6. Perbarui get_pixel_info untuk mengembalikan status proteksi
create or replace function get_pixel_info(p_x int, p_y int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  c config;
  p players;
  elapsed_ms numeric;
  px_record record;
  creator_nick text;
  v_is_protected boolean := false;
  v_is_owner boolean := false;
begin
  select * into c from config;
  if v_uid is not null then
    select * into p from players where id = v_uid;
    if p.banned then
      raise exception 'Akun Anda diblokir karena melanggar aturan komunitas';
    end if;

    if p.last_info_at is not null and coalesce(c.info_cooldown_ms, 500) > 0 then
      elapsed_ms := extract(epoch from (now() - p.last_info_at)) * 1000;
      if elapsed_ms < c.info_cooldown_ms then
        raise exception 'Terlalu cepat. Tunggu % ms sebelum memeriksa pixel lain.', c.info_cooldown_ms;
      end if;
    end if;

    update players set last_info_at = now() where id = v_uid;
  end if;

  select px.x, px.y, px.c, px.updated_at, px.uid, px.protected_until
  into px_record
  from pixels px
  where px.x = p_x and px.y = p_y;

  if not found then
    return null;
  end if;

  if px_record.uid is not null then
    select coalesce(nullif(trim(nick), ''), 'Anonim')
    into creator_nick
    from players
    where id = px_record.uid;

    if not found or creator_nick is null then
      creator_nick := 'Anonim';
    end if;
    v_is_owner := (v_uid is not null and px_record.uid = v_uid);
  else
    creator_nick := 'Anonim';
  end if;

  v_is_protected := (px_record.protected_until is not null and px_record.protected_until > now());

  return jsonb_build_object(
    'x', px_record.x,
    'y', px_record.y,
    'c', px_record.c,
    'nick', creator_nick,
    'at', px_record.updated_at,
    'is_protected', v_is_protected,
    'protected_until', px_record.protected_until,
    'is_owner', v_is_owner
  );
end $$;

revoke execute on function protect_pixels(jsonb) from public;
grant execute on function protect_pixels(jsonb) to authenticated;

revoke execute on function get_protected_pixels(jsonb) from public;
grant execute on function get_protected_pixels(jsonb) to anon, authenticated;
