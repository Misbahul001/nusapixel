-- Migration 008: Event & Target Bersama (Step 12)
-- Menambahkan event berjangka waktu (refill multiplier) dan target komunitas bershard (global goal)

-- 1. Kolom konfigurasi untuk batas pengali event dan boost global
alter table config add column if not exists event_max_mult numeric default 4;
alter table config add column if not exists global_boost_until timestamptz;

-- 2. Tabel events
create table if not exists events (
  id serial primary key,
  name text not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  refill_mult numeric not null default 1,
  banner text,
  constraint event_window_check check (ends_at > starts_at)
);

create index if not exists idx_events_window on events(starts_at, ends_at);

-- 3. Tabel global_goal & goal_counter (8 shard anti-contention)
create table if not exists global_goal (
  id serial primary key,
  name text not null,
  target bigint not null check (target > 0),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reward_boost_min int not null default 60,
  rewarded bool not null default false,
  constraint goal_window_check check (ends_at > starts_at)
);

create index if not exists idx_global_goal_window on global_goal(starts_at, ends_at);

create table if not exists goal_counter (
  goal_id int not null references global_goal(id) on delete cascade,
  shard smallint not null check (shard between 0 and 7),
  n bigint not null default 0,
  primary key (goal_id, shard)
);

-- Trigger otomatis membuat 8 shard (0..7) tiap ada goal baru
create or replace function init_goal_shards()
returns trigger language plpgsql as $$
begin
  insert into goal_counter(goal_id, shard, n)
  select new.id, s, 0
  from generate_series(0, 7) s;
  return new;
end $$;

drop trigger if exists trg_init_goal_shards on global_goal;
create trigger trg_init_goal_shards
after insert on global_goal
for each row execute function init_goal_shards();

-- 4. Seed data awal event & goal komunitas
insert into events (name, starts_at, ends_at, refill_mult, banner)
values (
  'Pekan Nusantara',
  now() - interval '1 hour',
  now() + interval '7 days',
  2,
  'Event Pekan Nusantara: Pengisian stok 2x lebih cepat untuk semua pemain!'
)
on conflict do nothing;

insert into global_goal (name, target, starts_at, ends_at, reward_boost_min)
values (
  'Target Bersama: 10.000 Pixel',
  10000,
  now() - interval '1 hour',
  now() + interval '7 days',
  60
)
on conflict do nothing;

-- 5. RPC get_event_state(): Polling berkala (60 detik) untuk event banner & bilah progres target
create or replace function get_event_state()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c config;
  ev record;
  gg record;
  total_progress bigint := 0;
begin
  select * into c from config;

  -- Event aktif saat ini
  select * into ev
  from events
  where now() between starts_at and ends_at
  order by id desc
  limit 1;

  -- Target bersama aktif saat ini
  select * into gg
  from global_goal
  where now() between starts_at and ends_at
  order by id desc
  limit 1;

  if gg.id is not null then
    select coalesce(sum(n), 0) into total_progress
    from goal_counter
    where goal_id = gg.id;
  end if;

  return jsonb_build_object(
    'event', case when ev.id is not null then jsonb_build_object(
      'id', ev.id,
      'name', ev.name,
      'refill_mult', least(coalesce(ev.refill_mult, 1), coalesce(c.event_max_mult, 4)),
      'banner', ev.banner,
      'ends_at', ev.ends_at
    ) else null end,
    'goal', case when gg.id is not null then jsonb_build_object(
      'id', gg.id,
      'name', gg.name,
      'target', gg.target,
      'current', total_progress,
      'pct', round(least(100, (total_progress::numeric / gg.target) * 100), 1),
      'rewarded', gg.rewarded,
      'reward_boost_min', gg.reward_boost_min,
      'ends_at', gg.ends_at
    ) else null end,
    'global_boost_until', c.global_boost_until,
    'global_boost_active', (c.global_boost_until is not null and c.global_boost_until > now())
  );
end $$;

revoke execute on function get_event_state() from public;
grant execute on function get_event_state() to anon, authenticated;
