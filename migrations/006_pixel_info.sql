-- Migration 006: Info Pixel & Riwayat Pembuat (Step 9)
-- Memungkinkan pemain melihat siapa yang menggambar pixel tanpa membocorkan identitas (uid)

-- 1. Tambah konfigurasi jeda info dan kolom penanda waktu kueri info pemain
alter table config add column if not exists info_cooldown_ms int default 500;
alter table players add column if not exists last_info_at timestamptz;

-- 2. RPC get_pixel_info: Mengembalikan info pixel {x, y, c, nick, at}
-- Sesuai Aturan #12: JANGAN PERNAH membocorkan auth.uid, hanya tampilkan nick / 'Anonim'
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

  -- 1. Batas laju pemanggilan RPC per pemain
  if p.last_info_at is not null and coalesce(c.info_cooldown_ms, 500) > 0 then
    elapsed_ms := extract(epoch from (now() - p.last_info_at)) * 1000;
    if elapsed_ms < c.info_cooldown_ms then
      raise exception 'Terlalu cepat. Tunggu sebentar sebelum memeriksa pixel lain';
    end if;
  end if;

  update players set last_info_at = now() where id = v_uid;

  -- 2. Cari pixel dan nama pembuatnya
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
