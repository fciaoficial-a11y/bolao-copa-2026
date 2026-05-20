begin;

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  display_name text not null default '',
  avatar_url text,
  role text not null default 'user' check (role in ('admin','creator','user'))
);

create table if not exists public.boards (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  slug text not null unique,
  description text,
  invite_code text not null unique,
  status text not null default 'draft' check (status in ('draft','active','finished','archived')),
  max_participants int not null default 20,
  allow_guest_access boolean not null default true,
  scoring_json jsonb not null default '{"exact":3,"winner":1,"draw":1,"lose":0}'::jsonb
);

create table if not exists public.board_members (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  board_id uuid not null references public.boards(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  nickname text not null,
  is_owner boolean not null default false,
  joined_at timestamptz not null default now(),
  total_points int not null default 0,
  unique (board_id, user_id),
  unique (board_id, nickname)
);

create table if not exists public.tournaments (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  name text not null,
  year int not null,
  slug text not null unique,
  status text not null default 'planned' check (status in ('planned','live','finished'))
);

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  code text not null,
  name text not null,
  unique (tournament_id, code)
);

create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  group_id uuid references public.groups(id) on delete set null,
  name text not null,
  short_name text,
  flag_url text,
  country_code text,
  unique (tournament_id, name)
);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  group_id uuid references public.groups(id) on delete set null,
  home_team_id uuid not null references public.teams(id),
  away_team_id uuid not null references public.teams(id),
  kickoff_at timestamptz not null,
  venue text,
  stage text not null default 'group',
  status text not null default 'scheduled' check (status in ('scheduled','live','finished','cancelled')),
  home_score int,
  away_score int,
  winner_team_id uuid references public.teams(id),
  external_source text,
  external_match_id text,
  unique (tournament_id, external_source, external_match_id)
);

create table if not exists public.predictions (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  board_id uuid not null references public.boards(id) on delete cascade,
  member_id uuid not null references public.board_members(id) on delete cascade,
  match_id uuid not null references public.matches(id) on delete cascade,
  home_score int not null check (home_score >= 0),
  away_score int not null check (away_score >= 0),
  points_awarded int not null default 0,
  locked boolean not null default false,
  unique (member_id, match_id)
);

create table if not exists public.points_events (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  board_id uuid not null references public.boards(id) on delete cascade,
  member_id uuid not null references public.board_members(id) on delete cascade,
  match_id uuid not null references public.matches(id) on delete cascade,
  prediction_id uuid not null references public.predictions(id) on delete cascade,
  points int not null,
  reason text not null,
  unique (prediction_id)
);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, role)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', new.email, ''), 'user')
  on conflict (id) do nothing;
  return new;
end;
$$;

create or replace function public.lock_prediction_if_match_started()
returns trigger
language plpgsql
as $$
declare
  v_kickoff timestamptz;
begin
  select kickoff_at into v_kickoff from public.matches where id = new.match_id;
  if v_kickoff is not null and now() >= v_kickoff then
    raise exception 'prediction locked: match already started';
  end if;
  return new;
end;
$$;

create or replace function public.recalculate_member_points(p_member_id uuid)
returns void
language plpgsql
as $$
begin
  update public.board_members bm
  set total_points = coalesce((select sum(points_awarded) from public.predictions p where p.member_id = p_member_id), 0),
      updated_at = now()
  where bm.id = p_member_id;
end;
$$;

create or replace function public.award_prediction_points(p_match_id uuid)
returns void
language plpgsql
as $$
declare
  r record;
  actual_home int;
  actual_away int;
  actual_winner uuid;
  predicted_winner uuid;
  pts int;
  reason text;
begin
  select home_score, away_score, winner_team_id into actual_home, actual_away, actual_winner
  from public.matches where id = p_match_id;

  for r in
    select p.*, m.home_team_id, m.away_team_id
    from public.predictions p
    join public.matches m on m.id = p.match_id
    where p.match_id = p_match_id
  loop
    pts := 0;
    reason := 'miss';

    if actual_home is null or actual_away is null then
      continue;
    end if;

    if r.home_score = actual_home and r.away_score = actual_away then
      pts := 3;
      reason := 'exact';
    else
      if actual_home > actual_away then
        actual_winner := r.home_team_id;
      elsif actual_away > actual_home then
        actual_winner := r.away_team_id;
      else
        actual_winner := null;
      end if;

      if r.home_score > r.away_score then
        predicted_winner := r.home_team_id;
      elsif r.away_score > r.home_score then
        predicted_winner := r.away_team_id;
      else
        predicted_winner := null;
      end if;

      if actual_winner is not null and predicted_winner = actual_winner then
        pts := 1;
        reason := 'winner';
      elsif actual_winner is null and predicted_winner is null then
        pts := 1;
        reason := 'draw';
      end if;
    end if;

    update public.predictions
    set points_awarded = pts,
        locked = true,
        updated_at = now()
    where id = r.id;

    insert into public.points_events(board_id, member_id, match_id, prediction_id, points, reason)
    values (r.board_id, r.member_id, r.match_id, r.id, pts, reason)
    on conflict (prediction_id) do update
    set points = excluded.points,
        reason = excluded.reason,
        created_at = now();

    perform public.recalculate_member_points(r.member_id);
  end loop;
end;
$$;

create or replace function public.on_match_finished_award_points()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'finished' then
    perform public.award_prediction_points(new.id);
  end if;
  return new;
end;
$$;

create or replace function public.on_new_board_member_defaults()
returns trigger
language plpgsql
as $$
begin
  if new.user_id is not null then
    update public.profiles set updated_at = now() where id = new.user_id;
  end if;
  return new;
end;
$$;

create trigger trg_profiles_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create trigger trg_boards_updated_at
before update on public.boards
for each row execute function public.set_updated_at();

create trigger trg_board_members_updated_at
before update on public.board_members
for each row execute function public.set_updated_at();

create trigger trg_tournaments_updated_at
before update on public.tournaments
for each row execute function public.set_updated_at();

create trigger trg_groups_updated_at
before update on public.groups
for each row execute function public.set_updated_at();

create trigger trg_teams_updated_at
before update on public.teams
for each row execute function public.set_updated_at();

create trigger trg_matches_updated_at
before update on public.matches
for each row execute function public.set_updated_at();

create trigger trg_predictions_updated_at
before update on public.predictions
for each row execute function public.set_updated_at();

create trigger trg_auth_user_profile
after insert on auth.users
for each row execute function public.create_profile_for_new_user();

create trigger trg_prediction_lock
before insert or update on public.predictions
for each row execute function public.lock_prediction_if_match_started();

create trigger trg_match_finished_points
after update of status, home_score, away_score on public.matches
for each row execute function public.on_match_finished_award_points();

create trigger trg_board_member_defaults
after insert on public.board_members
for each row execute function public.on_new_board_member_defaults();

alter table public.profiles enable row level security;
alter table public.boards enable row level security;
alter table public.board_members enable row level security;
alter table public.tournaments enable row level security;
alter table public.groups enable row level security;
alter table public.teams enable row level security;
alter table public.matches enable row level security;
alter table public.predictions enable row level security;
alter table public.points_events enable row level security;

create policy "profiles select own"
on public.profiles for select
using (auth.uid() = id or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

create policy "profiles update own"
on public.profiles for update
using (auth.uid() = id)
with check (auth.uid() = id);

create policy "boards select member"
on public.boards for select
using (
  exists (
    select 1 from public.board_members bm
    where bm.board_id = boards.id and bm.user_id = auth.uid()
  )
  or owner_id = auth.uid()
  or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

create policy "boards insert owner"
on public.boards for insert
with check (owner_id = auth.uid());

create policy "boards update owner"
on public.boards for update
using (owner_id = auth.uid() or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
with check (owner_id = auth.uid() or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

create policy "members select own board"
on public.board_members for select
using (
  user_id = auth.uid()
  or exists (
    select 1 from public.boards b where b.id = board_members.board_id and b.owner_id = auth.uid()
  )
  or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

create policy "members insert board owner"
on public.board_members for insert
with check (
  exists (select 1 from public.boards b where b.id = board_id and b.owner_id = auth.uid())
  or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

create policy "members update own or owner"
on public.board_members for update
using (
  user_id = auth.uid()
  or exists (select 1 from public.boards b where b.id = board_members.board_id and b.owner_id = auth.uid())
  or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
)
with check (
  user_id = auth.uid()
  or exists (select 1 from public.boards b where b.id = board_members.board_id and b.owner_id = auth.uid())
  or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

create policy "public tournaments read"
on public.tournaments for select
using (true);

create policy "public groups read"
on public.groups for select
using (true);

create policy "public teams read"
on public.teams for select
using (true);

create policy "public matches read"
on public.matches for select
using (true);

create policy "predictions select own board"
on public.predictions for select
using (
  exists (
    select 1 from public.board_members bm
    where bm.id = predictions.member_id and bm.user_id = auth.uid()
  )
  or exists (
    select 1 from public.boards b
    where b.id = predictions.board_id and b.owner_id = auth.uid()
  )
  or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

create policy "predictions insert own member"
on public.predictions for insert
with check (
  exists (
    select 1 from public.board_members bm
    where bm.id = member_id and bm.user_id = auth.uid()
  )
  or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

create policy "predictions update own member"
on public.predictions for update
using (
  exists (
    select 1 from public.board_members bm
    where bm.id = predictions.member_id and bm.user_id = auth.uid()
  )
  or exists (select 1 from public.boards b where b.id = predictions.board_id and b.owner_id = auth.uid())
  or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
)
with check (
  exists (
    select 1 from public.board_members bm
    where bm.id = predictions.member_id and bm.user_id = auth.uid()
  )
  or exists (select 1 from public.boards b where b.id = predictions.board_id and b.owner_id = auth.uid())
  or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

create policy "points events select own board"
on public.points_events for select
using (
  exists (
    select 1 from public.board_members bm
    where bm.id = points_events.member_id and bm.user_id = auth.uid()
  )
  or exists (
    select 1 from public.boards b where b.id = points_events.board_id and b.owner_id = auth.uid())
  or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

commit;