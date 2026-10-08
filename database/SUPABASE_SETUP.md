# Shared road reports setup

The Flutter app stores every report and finished road review locally first. The app now has the
project URL and publishable key configured as client-safe defaults, so the usual `flutter run`
command enables cloud sync without extra arguments. A publishable key is intended for client apps;
never put a `service_role` or secret key in the app.

1. Create a Supabase project and enable **Anonymous Sign-Ins** in Auth settings.
2. Run `supabase_road_reports.sql` in that project's SQL Editor for shared pothole reports and photos.
3. Run `supabase_road_reviews.sql` in that project's SQL Editor to create the GPS route review table and its access policies.
4. Run `supabase_profile_account.sql` in the SQL Editor for per-user profiles, private profile-photo storage, notifications, RLS, and self-service account deletion.
5. In Auth settings, enable email/password sign-in and email confirmations. Add `potholeai://auth-callback` to the allowed redirect URLs for email verification, email changes, and password resets. Keep anonymous sign-in enabled for guest mode.
6. The app is configured for project `cttjbuuzzocxokwdrhxv`. If you use a different project, copy its
   URL and publishable key from the Connect panel and override the defaults when building/running.
7. From the `mobile app` folder, run:

```powershell
flutter run
```

For a different project, add `--dart-define=SUPABASE_URL=...` and
`--dart-define=SUPABASE_PUBLISHABLE_KEY=...`. Re-run the SQL scripts in that
project: they create the shared-report/review tables and a private
`road-report-photos` bucket with a 10 MB per-photo limit. Report photos upload
there, and the app displays them through signed links that expire after one hour.
Local photos remain saved on the phone too.

Pothole report details/photos and GPS routes that a user explicitly starts and
finishes as road reviews are synced. The model-training dataset is not app
report data and is not part of this upload. Road reviews collect location only
while recording in the foreground; keep the app open during a recording.

Supabase's free plan can pause projects after a week without activity, so this
is suitable for development/demo use, not yet a reliability guarantee for a
public production service.
