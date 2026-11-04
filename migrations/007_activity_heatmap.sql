-- Migration 007: Peta Panas Aktivitas / Heatmap (Step 10)
-- Menghitung agregat kepadatan pixel 24 jam terakhir untuk memandu pemain baru ke area aktif

-- 1. Indeks pada updated_at untuk mempercepat kueri agregasi 24 jam
create index if not exists idx_pixels_updated_at on pixels(updated_at);

-- 2. Tabel heat: menyimpan agregasi tingkat zoom (Level 0: ~0.5°, Level 1: ~0.05°)
create table if not exists heat (
  level smallint not null,
  hx int not null,
  hy int not null,
  n int not null check (n > 0),
  primary key (level, hx, hy)
);

create index if not exists idx_heat_level on heat(level);

-- 3. Fungsi penyegaran berkala refresh_heat (dijalankan cron tiap 5 menit atau admin)
-- Ukuran agregasi: Level 0 = 500 sel (0.5 derajat), Level 1 = 50 sel (0.05 derajat)
create or replace function refresh_heat()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_count_l0 int := 0;
  v_count_l1 int := 0;
begin
  -- Hapus data heatmap lama
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

  return jsonb_build_object(
    'success', true,
    'level_0_cells', v_count_l0,
    'level_1_cells', v_count_l1,
    'refreshed_at', now()
  );
end $$;

-- 4. RPC get_heat(p_level): Mengembalikan larik ringkas [[hx, hy, n], ...]
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
