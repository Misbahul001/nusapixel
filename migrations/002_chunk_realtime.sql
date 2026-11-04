-- Migration 002: Realtime per Wilayah (Chunk) & Optimasi Skala (Step 2)
-- Menghindari batas 100 pesan realtime per detik dan mengefisienkan egress/kuota Supabase.

-- 1. Tambah koordinat chunk pada tabel pixels (64x64 sel per chunk)
alter table pixels add column if not exists cx int generated always as (floor(x::numeric / 64)::int) stored;
alter table pixels add column if not exists cy int generated always as (floor(y::numeric / 64)::int) stored;

-- Indeks komposit untuk lookup kilat per chunk
create index if not exists idx_pixels_chunk on pixels(cx, cy);

-- 2. Fungsi untuk memuat kumpulan chunk sekaligus (efisien, hemat egress)
create or replace function get_chunks(chunks jsonb)
returns table(x int, y int, c smallint)
language sql stable security definer set search_path = public as $$
  select p.x, p.y, p.c
  from pixels p
  join jsonb_to_recordset(chunks) as req(cx int, cy int)
    on p.cx = req.cx and p.cy = req.cy;
$$;

revoke all on function get_chunks(jsonb) from public;
grant execute on function get_chunks(jsonb) to anon, authenticated;

-- 3. Perbarui place_pixels untuk menyiarkan Realtime Broadcast per chunk
create or replace function place_pixels(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  c config;
  n int := jsonb_array_length(p);
  new_count int;
  r record;
begin
  if n < 1 or n > 20 then raise exception 'Jumlah pixel tidak valid'; end if;
  select * into c from config;
  if exists (select 1 from jsonb_to_recordset(p) as t(x int, y int)
             where x not between c.min_x and c.max_x or y not between c.min_y and c.max_y) then
    raise exception 'Kanvas hanya mencakup wilayah Indonesia';
  end if;
  me := refresh_player();

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
    update players set stock = stock - new_count, day_placed = day_placed + new_count, total_placed = total_placed + new_count where id = me.id;
  end if;

  -- Siarkan ke channel chunk masing-masing (dikelompokkan per chunk)
  -- Menggunakan Supabase Realtime Broadcast via SQL jika fungsi realtime.send tersedia
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

-- 4. Perbarui delete_pixels untuk menyiarkan Realtime Broadcast per chunk
create or replace function delete_pixels(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  c config;
  n int := jsonb_array_length(p);
  deleted_count int;
  r record;
begin
  if n < 1 or n > 20 then raise exception 'Jumlah pixel tidak valid'; end if;
  select * into c from config;
  me := refresh_player();

  with del as (
    delete from pixels where (x, y) in (
      select x, y from jsonb_to_recordset(p) as t(x int, y int)
    )
    returning x, y
  )
  select count(*) into deleted_count from del;

  if deleted_count > 0 then
    update players set stock = least(c.max_stock, stock + deleted_count) where id = me.id;

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
