-- Migration 005: Optimasi Biaya, Kuota, dan Sistem Pemantauan (Step 5)
-- Mengurangi egress Supabase Free tier hingga 70% dengan kompresi respons array ringkas,
-- serta menyediakan RPC statistik sistem real-time untuk dashboard moderasi/admin.

-- 1. RPC get_chunks_compact: Mengembalikan larik ringkas [[x,y,c], [x,y,c], ...]
-- Menghemat 60%+ ukuran transfer JSON dibanding objek dengan key {"x":...,"y":...,"c":...}
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

revoke execute on function get_chunks_compact(jsonb) from public;
grant execute on function get_chunks_compact(jsonb) to anon, authenticated;

-- 2. RPC get_system_stats: Pemantauan ukuran database, jumlah pixel, pemain, dan ambang kuota
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
  v_db_limit_bytes bigint := 500 * 1024 * 1024; -- 500 MB (Supabase Free)
begin
  -- Verifikasi hak admin
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

revoke execute on function get_system_stats() from public;
grant execute on function get_system_stats() to authenticated;
