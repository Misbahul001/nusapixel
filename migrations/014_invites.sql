-- ==============================================================================
-- Migrasi 014: Kode Undangan (Step 19)
-- - Konfigurasi batas hadiah undangan di tabel config
-- - Tabel invites(code text primary key, owner uuid, used_by uuid, used_at timestamptz, rewarded bool)
-- - RPC create_invite_code(): membuat kode 8-karakter (hanya akun non-anonim)
-- - RPC use_invite_code(p_code): memakai kode (1 kode per akun, bukan milik sendiri)
-- - RPC claim_invite_reward(p_code): mengklaim hadiah jika referee total_placed >= 100
-- - RPC get_my_invites(): membaca daftar kode undangan milik pemain dan status klaim
-- ==============================================================================

-- 1. Konfigurasi hadiah & batas undangan
alter table config add column if not exists invite_reward int default 100;
alter table config add column if not exists invite_max_claimed int default 10;
alter table config add column if not exists invite_min_placed int default 100;

update config set invite_reward = 100 where invite_reward is null;
update config set invite_max_claimed = 10 where invite_max_claimed is null;
update config set invite_min_placed = 100 where invite_min_placed is null;

-- 2. Tabel invites
create table if not exists invites (
  code text primary key,
  owner uuid not null references auth.users(id) on delete cascade,
  used_by uuid unique references auth.users(id) on delete set null,
  used_at timestamptz,
  rewarded bool not null default false,
  created_at timestamptz not null default now()
);

create index if not exists idx_invites_owner on invites(owner);
create index if not exists idx_invites_used_by on invites(used_by);

alter table invites enable row level security;
drop policy if exists "invites_read_policy" on invites;
create policy "invites_read_policy" on invites
  for select to authenticated
  using (owner = auth.uid() or used_by = auth.uid());

-- 3. RPC untuk melihat status undangan pemain
create or replace function get_my_invites() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  is_anon bool;
  c config;
  res jsonb;
  my_used record;
  rewarded_cnt int;
begin
  if auth.uid() is null then
    return jsonb_build_object('error', 'Belum login');
  end if;

  is_anon := coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false);
  select * into c from config;

  select count(*) into rewarded_cnt
  from invites
  where owner = auth.uid() and rewarded;

  select coalesce(jsonb_agg(r), '[]'::jsonb) into res from (
    select
      i.code,
      i.rewarded,
      i.used_at,
      case when i.used_by is not null then true else false end as is_used,
      coalesce(p.nick, 'Anonim') as friend_nick,
      coalesce(p.total_placed, 0) as friend_total_placed,
      coalesce(c.invite_min_placed, 100) as min_placed_needed,
      (coalesce(p.total_placed, 0) >= coalesce(c.invite_min_placed, 100) and not i.rewarded and i.used_by is not null) as can_claim
    from invites i
    left join players p on i.used_by = p.id
    where i.owner = auth.uid()
    order by i.created_at desc
  ) r;

  select code, used_at into my_used
  from invites
  where used_by = auth.uid();

  return jsonb_build_object(
    'is_anonymous', is_anon,
    'rewarded_count', rewarded_cnt,
    'max_claimed', coalesce(c.invite_max_claimed, 10),
    'reward_stock', coalesce(c.invite_reward, 100),
    'min_placed', coalesce(c.invite_min_placed, 100),
    'has_used_code', (my_used.code is not null),
    'used_code', my_used.code,
    'invites', res
  );
end $$;

revoke execute on function get_my_invites() from public;
grant execute on function get_my_invites() to authenticated;

-- 4. RPC untuk membuat kode undangan baru (8 karakter)
create or replace function create_invite_code() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  c config;
  active_count int;
  rewarded_count int;
  new_code text;
begin
  me := refresh_player();
  if me.banned then
    raise exception 'Akun Anda diblokir karena melanggar aturan komunitas';
  end if;

  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Masuk dengan Google atau Email terlebih dahulu untuk membuat kode undangan';
  end if;

  select * into c from config;

  select count(*) into active_count from invites where owner = me.id and (not rewarded);
  select count(*) into rewarded_count from invites where owner = me.id and rewarded;

  if rewarded_count >= coalesce(c.invite_max_claimed, 10) then
    raise exception 'Batas maksimal % hadiah undangan telah tercapai', coalesce(c.invite_max_claimed, 10);
  end if;

  if active_count >= coalesce(c.invite_max_claimed, 10) then
    raise exception 'Anda memiliki % kode aktif yang belum selesai. Bagikan kode tersebut terlebih dahulu.', active_count;
  end if;

  -- Buat kode acak 8 karakter unik
  loop
    new_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from invites where code = new_code);
  end loop;

  insert into invites(code, owner)
  values (new_code, me.id);

  return get_my_invites();
end $$;

revoke execute on function create_invite_code() from public;
grant execute on function create_invite_code() to authenticated;

-- 5. RPC untuk menggunakan kode undangan pemain lain
create or replace function use_invite_code(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  inv invites;
  c config;
  clean_code text := upper(trim(p_code));
begin
  me := refresh_player();
  if me.banned then
    raise exception 'Akun Anda diblokir karena melanggar aturan komunitas';
  end if;

  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'Masuk dengan Google atau Email terlebih dahulu untuk menggunakan kode undangan';
  end if;

  if clean_code is null or length(clean_code) < 6 then
    raise exception 'Kode undangan tidak valid';
  end if;

  -- Periksa apakah pemain sudah pernah memakai kode
  if exists (select 1 from invites where used_by = me.id) then
    raise exception 'Akun Anda sudah pernah menggunakan kode undangan';
  end if;

  select * into inv from invites where code = clean_code;
  if not found then
    raise exception 'Kode undangan tidak ditemukan';
  end if;

  if inv.owner = me.id then
    raise exception 'Tidak dapat menggunakan kode undangan milik sendiri';
  end if;

  if inv.used_by is not null then
    raise exception 'Kode undangan ini sudah digunakan oleh pemain lain';
  end if;

  update invites
  set used_by = me.id,
      used_at = now()
  where code = clean_code;

  -- Hadiah sambutan untuk pemain baru (+25 stok instan)
  update players
  set stock = least(max_stock, stock + 25)
  where id = me.id;

  return jsonb_build_object(
    'status', 'ok',
    'code', clean_code,
    'bonus_stock', 25,
    'message', 'Kode undangan berhasil digunakan! Anda mendapatkan +25 stok pixel.'
  );
end $$;

revoke execute on function use_invite_code(text) from public;
grant execute on function use_invite_code(text) to authenticated;

-- 6. RPC untuk mengklaim hadiah undangan bagi pemilik kode
create or replace function claim_invite_reward(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me players;
  inv invites;
  referee players;
  c config;
  rewarded_count int;
  clean_code text := upper(trim(p_code));
begin
  me := refresh_player();
  if me.banned then
    raise exception 'Akun Anda diblokir karena melanggar aturan komunitas';
  end if;

  select * into inv from invites where code = clean_code and owner = me.id;
  if not found then
    raise exception 'Kode undangan tidak ditemukan atau bukan milik Anda';
  end if;

  if inv.rewarded then
    raise exception 'Hadiah untuk kode undangan ini sudah diklaim';
  end if;

  if inv.used_by is null then
    raise exception 'Kode undangan ini belum digunakan oleh siapa pun';
  end if;

  select * into referee from players where id = inv.used_by;
  select * into c from config;

  if coalesce(referee.total_placed, 0) < coalesce(c.invite_min_placed, 100) then
    raise exception 'Teman Anda baru menempatkan % pixel (dibutuhkan minimal % pixel untuk mengklaim hadiah)',
      coalesce(referee.total_placed, 0), coalesce(c.invite_min_placed, 100);
  end if;

  select count(*) into rewarded_count from invites where owner = me.id and rewarded;
  if rewarded_count >= coalesce(c.invite_max_claimed, 10) then
    raise exception 'Batas maksimal % hadiah undangan berhasil telah tercapai', coalesce(c.invite_max_claimed, 10);
  end if;

  -- Beri hadiah ke pemilik kode
  update invites set rewarded = true where code = clean_code;
  update players set stock = least(max_stock, stock + coalesce(c.invite_reward, 100)) where id = me.id;

  return jsonb_build_object(
    'status', 'ok',
    'code', clean_code,
    'reward_stock', coalesce(c.invite_reward, 100),
    'state', get_state()
  );
end $$;

revoke execute on function claim_invite_reward(text) from public;
grant execute on function claim_invite_reward(text) to authenticated;
