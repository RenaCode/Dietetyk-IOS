# Dietetyk iOS

Native iOS client (SwiftUI) for [Dietetyk AI](https://github.com/RenaCode/Dietetyk-AI), a
calorie and macro tracker with AI meal analysis and a daily health dashboard. The app is a thin
client over the existing Dietetyk AI backend and adds native Apple Health (HealthKit) sync.

**Status:** pre-release (version 0.1.0). The app is not yet distributed through the App Store or
TestFlight.

## Features

- **Sign-in** with username and password, including two-factor authentication (TOTP code,
  first-time 2FA setup with QR code and secret) and the forced password change flow.
- **Dashboard** for any day (previous/next day navigation):
  - calories eaten vs. target, active and total calories burned (including BMR), net balance,
  - macros (protein, carbs, fat) vs. targets,
  - activity: steps and active minutes vs. targets, last sync time,
  - water intake with quick-add buttons and reset,
  - sleep and readiness (Oura): sleep score and duration, readiness, HRV, resting heart rate,
  - body composition (Withings / Apple Health): weight, body fat, muscle mass,
  - the AI dietitian's advice for the day and the list of the day's meals.
- **Meals**: per-day list with total calories, swipe to delete, meal details (nutrition values,
  ingredients, health rating, AI dietitian's comment). New meals are added from a text
  description and/or a photo (camera or photo library). The backend's AI analyses the input and
  may return several meals from a single photo.
- **Settings**: profile (username, e-mail), daily goals (calories, protein, carbs, fat, water),
  Apple Health sync, backend address, sign-out.
- **Apple Health sync** (read-only, see below).

Not implemented yet: Google sign-in, admin panel, trends charts (`APIClient.fetchHealthHistory()`
exists but has no screen), push notifications.

## Apple Health (HealthKit) sync

The app reads from HealthKit (it never writes to it) and sends the data to the same backend
endpoint that accepts payloads from the third-party "Health Auto Export" app,
`POST /api/integrations/apple-health/:syncToken`. `Models/HealthExportModels.swift` reproduces
that JSON format, so the backend needs no changes and the app replaces the Health Auto Export
automation.

Data read from HealthKit:

| HealthKit type | Sent as |
|---|---|
| `stepCount` | `step_count` |
| `activeEnergyBurned` | `active_energy` |
| `basalEnergyBurned` | `basal_energy_burned` |
| `appleExerciseTime` | `apple_exercise_time` |
| `distanceWalkingRunning` | `walking_running_distance` |
| `appleSleepingWristTemperature` (Apple Watch Series 8+/Ultra) | `wrist_temperature` |
| workouts (`HKWorkout`) | `workouts` |

The backend accepts a few more metrics (for example water, resting heart rate and HRV) that the
app does not send yet. Weight, body composition and sleep reach the backend through other
integrations (Withings, Oura).

How it works:

- Turned on and off in **Ustawienia → Synchronizacja zdrowia**. The system permission prompt
  appears the first time it is turned on.
- Each run syncs the last 14 days. The backend overwrites the same days, so repeated runs are safe.
- Sync runs when the app starts and returns to the foreground. While it is enabled, an
  `HKObserverQuery` with hourly background delivery (`enableBackgroundDelivery`) starts a sync
  when new step, energy, exercise-time or distance samples arrive, without opening the app.
  **Synchronizuj teraz** starts a sync manually.
- The sync token (`sync_token`) is fetched automatically from `/api/settings`; the user does not
  enter it anywhere.
- The section is hidden on devices without Health data (for example some iPads).

## Requirements

- macOS with Xcode 16 or later. Deployment target: iOS 17.0, iPhone and iPad, portrait only.
  Swift language version 5.9 (`SWIFT_VERSION` in `project.yml`).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen). The repository does not commit the
  `.xcodeproj` or the `.entitlements` file; both are generated from `project.yml`:

  ```sh
  brew install xcodegen
  ```

No third-party dependencies (no Swift packages or CocoaPods).

## Building

```sh
git clone https://github.com/RenaCode/Dietetyk-IOS.git
cd Dietetyk-IOS
xcodegen generate
open Dietetyk.xcodeproj
```

In Xcode, select your development team under Signing & Capabilities (`DEVELOPMENT_TEAM` is
intentionally empty in `project.yml`), choose a simulator or device and run (Cmd+R). HealthKit
with background delivery is enabled through the generated entitlements, so a device build needs a
team that can use the HealthKit capability.

## Tests and CI

`DietetykTests/` holds unit tests for logic that needs no live HealthKit or network: API date
formatting, backend address validation and token clearing when the address changes, the Health
Auto Export payload encoding, sync service logic, settings decoding and lenient number decoding.

Run them locally from Xcode (Cmd+U) or with `xcodebuild test -scheme Dietetyk` against a
simulator. GitHub Actions (`.github/workflows/ci.yml`) runs on every push, on pull requests to
`main` and manually. It uses `macos-15` with the latest stable Xcode, generates the project with
XcodeGen, picks an available iPhone simulator at runtime and runs `xcodebuild test` without code
signing.

## Backend address

The default backend is `https://dietetyk.renacode.com` (`Networking/APIConfig.swift`). It can be
changed in the app under **Ustawienia → Adres serwera**, for example to point at a self-hosted
backend or `http://localhost:3000` during development. The value is stored in `UserDefaults`, so no
rebuild is needed; **Przywróć domyślny** restores the default.

Only `https` and `http` URLs with a host are accepted. App Transport Security is on with no
exceptions, so plain `http` works only for localhost. **Changing the address signs you out:** the
session token in the Keychain belongs to one backend, and keeping it would send a live token to a
different host.

## Architecture

- **SwiftUI + MVVM.** Each screen has a `View` and a `@MainActor` `ObservableObject` view model
  with `@Published` state. Networking uses `async/await`; no DI or reactive frameworks.
- **`Networking/APIClient`**: a small HTTP client over `URLSession` with no external
  dependencies. Endpoints are grouped in extensions (`APIClient+Auth`, `+Dashboard`, `+Meals`,
  `+Settings`, `+Health`). The session token is sent as `Authorization: Bearer <token>`; the
  backend does not use cookies.
- **`Networking/KeychainStore`**: the session token lives in the Keychain. The backend address
  and goals are not secret and live in `UserDefaults` or on the backend.
- **`Models/`**: `Codable` structs decoded with `keyDecodingStrategy = .convertFromSnakeCase`
  (backend `target_calories` becomes Swift `targetCalories`). Numeric fields are decoded
  leniently (`LenientNumbers.swift`), so one unexpected value does not break a whole list.
- **`Health/`**: `HealthKitManager` (authorization, types), `HealthSyncService` (an `actor` that
  serialises manual and background syncs) and `HealthSyncPreferences`.
- No Core Data or SwiftData. Data is not cached on the device, so the app needs the backend to be
  reachable.

## API used (backend `Dietetyk-AI`)

| Endpoint | Method | Auth | Purpose |
|---|---|---|---|
| `/api/login` | POST | no | `{username,password}` → `{token}` or `{status:"require_2fa"\|"setup_2fa"\|"force_password_change", tempToken}` |
| `/api/login-2fa` | POST | no | `{tempToken,code}` → `{token}` |
| `/api/verify-2fa-setup` | POST | no | `{tempToken,code}` → `{token}` (first 2FA setup) |
| `/api/change-password-forced` | POST | no | `{tempToken,newPassword}` → `{token}` or the next 2FA step |
| `/api/logout` | POST | yes | invalidates the token |
| `/api/dashboard?date=YYYY-MM-DD` | GET | yes | day summary (calories, macros, health), meals, AI advice |
| `/api/meals?date=YYYY-MM-DD` | GET | yes | meals for a day |
| `/api/meals` | POST | yes | `{rawText?, image? (base64 data URL), date?}` → AI analysis and save (may return several meals) |
| `/api/meals/:id` | DELETE | yes | deletes a meal |
| `/api/settings` | GET / POST | yes | calorie, macro and water goals; `sync_token` for Apple Health |
| `/api/user/profile` | GET | yes | username and e-mail shown in Settings |
| `/api/water/add`, `/api/water/reset` | POST | yes | water intake counter |
| `/api/health/history` | GET | yes | health metrics history (client method only, no UI yet) |
| `/api/integrations/apple-health/:syncToken` | POST | sync token in URL | HealthKit data in Health Auto Export format |

Sessions last 7 days, are extended while in use, and expire at an absolute limit set by the
backend.

## Project layout

```
Dietetyk/
  App/          entry point, AppState (session/routing), tabs, day navigator
  Networking/   APIClient (+ extensions), APIError, APIConfig, KeychainStore, lenient number decoding
  Models/       Codable models
  Health/       HealthKitManager, HealthSyncService, HealthSyncPreferences
  Features/
    Auth/       sign-in, 2FA, forced password change
    Dashboard/  daily dashboard
    Meals/      meal list, details, adding (text/photo/camera)
    Settings/   profile, goals, Apple Health sync, backend address, sign-out
DietetykTests/  unit tests
project.yml     XcodeGen project definition
```

## License

[MIT](LICENSE)
