-- Migration 001: Pembatasan Laju dan Penguatan Server (Step 1)
-- Menutup celah spam, bot skrip, dan memindahkan parameter batas ke config.

-- 1. Tambah kolom batas laju dan ukuran batch di tabel config
alter table config add column if not exists max_batch_size int default 20;
alter table config add column if not exists rate_limit_px_per_sec numeric default 5;

-- 2. Tambah kolom pencatatan waktu penempatan terakhir di tabel players
alter table players add column if not exists last_placed_at timestamptz default now();

-- 3. Perbarui place_pixels untuk menegakkan batas laju & batas batch dinamis
create or replace function place_pixels(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  c config;
  n int := jsonb_array_length(p);
  new_count int;
  elapsed_sec numeric;
  min_interval_sec numeric;
  r record;
begin
  select * into c from config;

  -- Validasi ukuran batch dari config
  if n < 1 or n > coalesce(c.max_batch_size, 20) then
    raise exception 'Ukuran batch tidak valid (maksimal %)', coalesce(c.max_batch_size, 20);
  end if;

  -- Validasi koordinat wilayah Indonesia
  if exists (select 1 from jsonb_to_recordset(p) as t(x int, y int)
             where x not between c.min_x and c.max_x or y not between c.min_y and c.max_y) then
    raise exception 'Kanvas hanya mencakup wilayah Indonesia';
  end if;

  me := refresh_player();

  -- Penegakan batas laju (rate limiting per pemain)
  if me.last_placed_at is not null and coalesce(c.rate_limit_px_per_sec, 5) > 0 then
    elapsed_sec := extract(epoch from (now() - me.last_placed_at));
    -- Waktu minimum yang dibutuhkan untuk menempatkan n pixel
    min_interval_sec := (n::numeric / c.rate_limit_px_per_sec) * 0.8; -- toleransi 20% untuk jitter jaringan
    if elapsed_sec < min_interval_sec then
      raise exception 'Terlalu cepat. Kecepatan maksimal adalah % pixel per detik', c.rate_limit_px_per_sec;
    end if;
  end if;

  -- Hitung hanya pixel baru (grid yang belum ada di tabel pixels)
  select count(*) into new_count
  from jsonb_to_recordset(p) as t(x int, y int)
  where not exists (select 1 from pixels px where px.x = t.x and px.y = t.y);

  if new_count > 0 and floor(me.stock) < new_count then
    raise exception 'Stok pixel tidak cukup';
  end if;

  insert into pixels(x, y, c, uid)
    select x, y, c, auth.uid() from jsonb_to_recordset(p) as t(x int, y int, c smallint)
  on conflict (x, y) do update set c = excluded.c, uid = excluded.uid, updated_at = now();

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

  -- Siarkan Realtime Broadcast per chunk jika realtime.send tersedia (Step 2)
  if exists (select 1 from pg_proc where proname = 'send' and pronamespace = 'realtime'::regnamespace) then
    for r in (
      select
        floor(x::numeric / 64)::int as cx,
        floor(y::numeric / 64)::int as cy,
        jsonb_agg(jsonb_build_object('x', x, 'y', y, 'c', c)) as p_list
      from jsonb_to_recordset(p) as t(x int, y int, c smallint)
      group by floor(x::numeric / 64)::int, floor(y::numeric / 64)::int
    ) loop
      perform realtime.send(
        jsonb_build_object('p', r.p_list),
        'pixels',
        'chunk:' || r.cx || '_' || r.cy
      );
    end loop;
  end if;

  return get_state();
end $$;
