-- Run this in the Supabase SQL Editor for the shared reports MVP.
-- Client apps must use the publishable key and authenticated user sessions.
-- Never ship a service-role key in the Flutter app.

create table if not exists public.road_reports (
  client_id text primary key,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  issue_type text not null check (issue_type in ('Pothole', 'Damaged road')),
  severity text not null check (severity in ('Medium', 'Major')),
  description text not null default '',
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_meters double precision not null check (accuracy_meters >= 0),
  photo_url text,
  photo_storage_path text,
  status text not null default 'open'
    check (status in ('open', 'confirmed', 'repaired', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_confirmed_at timestamptz
);

alter table public.road_reports
  add column if not exists photo_storage_path text;

create index if not exists road_reports_created_at_idx
  on public.road_reports (created_at desc);
create index if not exists road_reports_location_idx
  on public.road_reports (latitude, longitude);

alter table public.road_reports enable row level security;

revoke all on public.road_reports from anon;
grant select (
  client_id, issue_type, severity, description, latitude, longitude,
  accuracy_meters, photo_url, photo_storage_path, status, created_at,
  updated_at, last_confirmed_at
) on public.road_reports to authenticated;
grant insert (
  client_id, reporter_id, issue_type, severity, description, latitude,
  longitude, accuracy_meters, photo_url, photo_storage_path, created_at
) on public.road_reports to authenticated;
grant update (status, updated_at, last_confirmed_at, photo_storage_path)
  on public.road_reports to authenticated;

drop policy if exists "Signed-in users can view road reports"
  on public.road_reports;
create policy "Signed-in users can view road reports"
  on public.road_reports for select to authenticated using (true);

drop policy if exists "Users can create their own road reports"
  on public.road_reports;
create policy "Users can create their own road reports"
  on public.road_reports for insert to authenticated
  with check (auth.uid() = reporter_id);

drop policy if exists "Users can update their own road report status"
  on public.road_reports;
create policy "Users can update their own road report status"
  on public.road_reports for update to authenticated
  using (auth.uid() = reporter_id)
  with check (auth.uid() = reporter_id);

-- Private photo storage: only authenticated app users can read shared photos;
-- each user can upload/replace objects inside their own UUID folder.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'road-report-photos', 'road-report-photos', false, 10485760,
  array['image/jpeg']::text[]
)
on conflict (id) do update set
  public = false,
  file_size_limit = 10485760,
  allowed_mime_types = array['image/jpeg']::text[];

drop policy if exists "Authenticated users can view road report photos"
  on storage.objects;
create policy "Authenticated users can view road report photos"
  on storage.objects for select to authenticated
  using (bucket_id = 'road-report-photos');

drop policy if exists "Users can upload photos to their own folder"
  on storage.objects;
create policy "Users can upload photos to their own folder"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'road-report-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Users can replace photos in their own folder"
  on storage.objects;
create policy "Users can replace photos in their own folder"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'road-report-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'road-report-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
