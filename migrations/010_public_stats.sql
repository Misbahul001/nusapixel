-- ====================================================================
-- MIGRATION 010: STATISTIK PUBLIK & TABEL STATS (Step 15)
-- ====================================================================
-- Deskripsi:
-- 1. Menyediakan tabel tunggal `stats` (id=1) untuk menyimpan agregasi statistik kanvas.
-- 2. Menghindari full table scan / count(*) berulang setiap pengunjung membuka halaman beranda.
-- 3. Diperbarui bersamaan dengan cron / penyegaran Step 10 (refresh_heat).
-- 4. RPC `get_public_stats()` membaca 1 baris statis secara instan dan hemat kuota.
-- ====================================================================

create table if not exists stats (
  id int primary key default 1 check (id = 1),
  total_pixels bigint not null default 0,
  total_players bigint not null default 0,
  today_pixels bigint not null default 0,
  updated_at timestamptz not null default now()
);

-- Inisialisasi baris pertama dengan data awal
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

-- RLS tabel stats
alter table stats enable row level security;
drop policy if exists p_stats_read on stats;
create policy p_stats_read on stats for select using (true);

-- Perbarui fungsi refresh_heat() untuk memperbarui tabel stats
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
  where updated_at >= now() - interval '24 hours'
  group by floor(x::numeric / 500)::int, floor(y::numeric / 500)::int;
  get diagnostics v_count_l0 = row_count;

  -- Level 1 (Zoom 10-15): Agregasi per 50 sel (0.05°)
  insert into heat (level, hx, hy, n)
  select
    1 as level,
    floor(x::numeric / 50)::int as hx,
    floor(y::numeric / 50)::int as hy,
    count(*)::int as n
  from pixels
  where updated_at >= now() - interval '24 hours'
  group by floor(x::numeric / 50)::int, floor(y::numeric / 50)::int;
  get diagnostics v_count_l1 = row_count;

  -- Perbarui tabel stats untuk get_public_stats (Step 15)
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

  return jsonb_build_object(
    'level_0_cells', v_count_l0,
    'level_1_cells', v_count_l1,
    'total_pixels', v_tot_px,
    'total_players', v_tot_pl,
    'today_pixels', v_today_px,
    'refreshed_at', now()
  );
end $$;

-- RPC get_public_stats: Cepat dan hemat kuota, hanya membaca 1 baris tabel stats
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
