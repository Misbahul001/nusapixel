-- ====================================================================
-- MIGRATION 011: TIME-LAPSE & SNAPSHOT CHUNK (Step 16)
-- ====================================================================
-- Deskripsi:
-- 1. Tabel snapshots menyimpan keadaan chunk (64x64 sel) per hari dengan format 4-bit per sel (2048 byte).
-- 2. Hanya chunk yang mengalami perubahan hari itu yang disimpan.
-- 3. Retensi 30 hari: snapshot lebih lama dari 30 hari otomatis dibersihkan.
-- 4. Pengaman kuota: jika ukuran database melampaui 70% dari 500 MB (350 MB), pembuatan snapshot berhenti.
-- 5. RPC get_snapshots mengembalikan larik ringkas, dibatasi maks 50 chunk dan 14 hari per putaran.
-- ====================================================================

create table if not exists snapshots (
  day date not null,
  cx int not null,
  cy int not null,
  data bytea not null,
  primary key (day, cx, cy)
);

create index if not exists idx_snapshots_day on snapshots(day);

-- RLS: Akses baca publik
alter table snapshots enable row level security;
drop policy if exists p_snapshots_read on snapshots;
create policy p_snapshots_read on snapshots for select using (true);

-- Fungsi internal: Mengubah pixel chunk 64x64 menjadi 2048 byte bytea (4-bit per sel)
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
  -- Inisialisasi array 4096 karakter '0' (sel kosong / default)
  v_chars := array_fill('0'::text, array[4096]);

  for v_rec in
    select x, y, c
    from pixels
    where cx = p_cx and cy = p_cy
  loop
    v_rx := (v_rec.x - p_cx * 64);
    v_ry := (v_rec.y - p_cy * 64);
    if v_rx >= 0 and v_rx < 64 and v_ry >= 0 and v_ry < 64 then
      v_idx := (v_ry * 64 + v_rx) + 1; -- 1-based index di Postgres
      v_chars[v_idx] := to_hex(least(15, greatest(1, v_rec.c + 1)));
    end if;
  end loop;

  v_hex := array_to_string(v_chars, '');
  return decode(v_hex, 'hex');
end $$;

-- Fungsi harian: Membuat snapshot dan membersihkan data > 30 hari
create or replace function create_daily_snapshots(
  p_day date default (now() at time zone 'Asia/Jakarta')::date - interval '1 day',
  p_test_max_bytes bigint default null
)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_db_bytes bigint;
  v_max_bytes bigint := coalesce(p_test_max_bytes, (500 * 1024 * 1024 * 0.70)::bigint); -- 70% dari 500 MB (350 MB)
  v_rec record;
  v_count int := 0;
  v_deleted int := 0;
  v_snap_bytes bytea;
begin
  -- 1. Pengaman kuota database (Aturan Step 16)
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

  -- 2. Pembersihan retensi 30 hari
  delete from snapshots
  where day < (p_day - interval '30 days');
  get diagnostics v_deleted = row_count;

  -- 3. Rekam snapshot untuk setiap chunk yang berubah pada tanggal p_day
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

-- RPC get_snapshots: Mengembalikan larik ringkas untuk area putar ulang
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
