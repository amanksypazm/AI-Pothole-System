-- Run this migration in Supabase SQL Editor after the road_reports setup.
-- Road paths are stored as ordered GPS coordinate arrays (no PostGIS required).

create table if not exists public.road_reviews (
  client_id text primary key,
  reviewer_id uuid not null references auth.users(id) on delete cascade,
  start_latitude double precision not null check (start_latitude between -90 and 90),
  start_longitude double precision not null check (start_longitude between -180 and 180),
  end_latitude double precision not null check (end_latitude between -90 and 90),
  end_longitude double precision not null check (end_longitude between -180 and 180),
  route_points jsonb not null check (
    jsonb_typeof(route_points) = 'array'
    and jsonb_array_length(route_points) between 2 and 5000
  ),
  distance_meters double precision not null check (distance_meters >= 0),
  duration_seconds integer not null check (duration_seconds >= 0),
  rating smallint not null check (rating between 1 and 10),
  recommend boolean not null,
  comment text not null default '' check (char_length(comment) <= 300),
  created_at timestamptz not null default now()
);

alter table public.road_reviews
  add column if not exists duration_seconds integer not null default 0
    check (duration_seconds >= 0);

create index if not exists road_reviews_created_at_idx
  on public.road_reviews (created_at desc);

alter table public.road_reviews enable row level security;
revoke all on public.road_reviews from anon;
grant select (
  client_id, start_latitude, start_longitude, end_latitude, end_longitude,
  route_points, distance_meters, duration_seconds, rating, recommend,
  comment, created_at
) on public.road_reviews to authenticated;
grant insert (
  client_id, reviewer_id, start_latitude, start_longitude, end_latitude,
  end_longitude, route_points, distance_meters, duration_seconds, rating,
  recommend, comment, created_at
) on public.road_reviews to authenticated;

drop policy if exists "Authenticated users can view road reviews"
  on public.road_reviews;
create policy "Authenticated users can view road reviews"
  on public.road_reviews for select to authenticated using (true);

drop policy if exists "Users can create their own road reviews"
  on public.road_reviews;
create policy "Users can create their own road reviews"
  on public.road_reviews for insert to authenticated
  with check (auth.uid() = reviewer_id);
