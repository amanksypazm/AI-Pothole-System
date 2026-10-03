# Shared road reports setup

The Flutter app stores every report and finished road review locally first. Cloud sync is enabled only
when the app is built with a Supabase project URL and publishable key.

1. Create a Supabase project and enable **Anonymous Sign-Ins** in Auth settings.
2. Run `supabase_road_reports.sql` in that project's SQL Editor for shared pothole reports and photos.
3. Run `supabase_road_reviews.sql` in that project's SQL Editor to create the GPS route review table and its access policies.
4. Copy the project URL and publishable key from the project's Connect panel.
5. From the `mobile app` folder, build/run Flutter with:

```powershell
flutter run --dart-define=SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

Use the same values with `flutter build apk --release --target-platform
android-arm64` when making a smaller APK for modern Android phones. Never put
a `service_role` or secret key in the app. Re-run the SQL script after updating
the app: it creates a private `road-report-photos` bucket with a 10 MB per-photo
limit. Report photos upload there, and the app displays them through signed
links that expire after one hour. Local photos remain saved on the phone too.

Pothole report details/photos and GPS routes that a user explicitly starts and
finishes as road reviews are synced. The model-training dataset is not app
report data and is not part of this upload. Road reviews collect location only
while recording in the foreground; keep the app open during a recording.

Supabase's free plan can pause projects after a week without activity, so this
is suitable for development/demo use, not yet a reliability guarantee for a
public production service.
