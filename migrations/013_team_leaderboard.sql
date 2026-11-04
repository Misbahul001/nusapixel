-- ==============================================================================
-- Migrasi 013: Peringkat Tim Provinsi (Step 18)
-- - Menambahkan kolom team_id dan last_team_change pada tabel players
-- - Menambahkan konfigurasi team_change_cooldown_days pada config (default 7 hari)
-- - Membuat tabel agregasi team_board yang diperbarui berkala via refresh_team_board()
-- - Membaca leaderboard tim dari tabel agregat (get_team_board) tanpa recalculate players
-- - Memungkinkan pemilihan/penggantian tim provinsi (set_team) dengan cooldown 7 hari
-- - Mengembalikan daftar provinsi (get_regions)
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

-- Hubungkan penyegaran team_board ke fungsi refresh_heat() rutin (tiap 5 menit)
create or replace function refresh_heat() returns void
language plpgsql security definer set search_path = public as $$
begin
  -- Agregasi Level 0 (Ukuran 500 sel, radius 0.5 derajat)
  insert into heat(level, hx, hy, n)
  select
    0 as level,
    floor(x / 500.0)::int as hx,
    floor(y / 500.0)::int as hy,
    count(*)::int as n
  from pixels
  where updated_at >= now() - interval '24 hours'
  group by 1, 2, 3
  on conflict (level, hx, hy) do update set n = excluded.n;

  delete from heat where level = 0 and (hx, hy) not in (
    select floor(x / 500.0)::int, floor(y / 500.0)::int
    from pixels
    where updated_at >= now() - interval '24 hours'
    group by 1, 2
  );

  -- Agregasi Level 1 (Ukuran 50 sel, radius 0.05 derajat)
  insert into heat(level, hx, hy, n)
  select
    1 as level,
    floor(x / 50.0)::int as hx,
    floor(y / 50.0)::int as hy,
    count(*)::int as n
  from pixels
  where updated_at >= now() - interval '24 hours'
  group by 1, 2, 3
  on conflict (level, hx, hy) do update set n = excluded.n;

  delete from heat where level = 1 and (hx, hy) not in (
    select floor(x / 50.0)::int, floor(y / 50.0)::int
    from pixels
    where updated_at >= now() - interval '24 hours'
    group by 1, 2
  );

  -- Perbarui statistik publik (Step 15)
  perform refresh_public_stats();

  -- Perbarui peringkat tim provinsi (Step 18)
  perform refresh_team_board();
end $$;

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
