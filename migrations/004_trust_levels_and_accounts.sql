-- Migration 004: Tingkat Kepercayaan & Penguatan Akun (Step 4)
-- Membatasi akun bot/burner baru ke stok kecil (75) dan menaikkan stok bertahap
-- hingga 500 untuk pemain terpercaya tanpa kehilangan data saat menautkan akun.

-- 1. Tambah kolom tingkat kepercayaan dan stok maksimal dinamis pada tabel players
alter table players add column if not exists trust_level int default 1;
alter table players add column if not exists max_stock int default 75;
alter table players add column if not exists active_days int default 1;
alter table players add column if not exists created_at timestamptz default now();

-- 2. Perbarui refresh_player untuk menghitung stok maksimal dinamis berdasarkan reputasi
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

  -- Hitung isi ulang stok hingga batas max_stock milik pemain
  el := extract(epoch from now() - p.stock_at);
  bs := greatest(0, extract(epoch from least(now(), p.boost_until) - p.stock_at));
  if p.stock < p.max_stock then
    p.stock := least(p.max_stock, p.stock + bs / c.boost_refill_sec + (el - bs) / c.refill_sec);
  end if;
  p.stock_at := now();

  update players set
    stock = p.stock,
    stock_at = p.stock_at,
    day = p.day,
    day_placed = p.day_placed,
    claimed = p.claimed,
    ads_today = p.ads_today,
    active_days = p.active_days,
    trust_level = p.trust_level,
    max_stock = p.max_stock
  where id = p.id;

  return p;
end $$;

-- 3. Perbarui delete_pixels untuk membatasi pengembalian stok sesuai max_stock pemain
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
  if n < 1 or n > coalesce(c.max_batch_size, 20) then
    raise exception 'Jumlah pixel tidak valid';
  end if;
  me := refresh_player();
  if me.banned then raise exception 'Akun Anda diblokir'; end if;

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
