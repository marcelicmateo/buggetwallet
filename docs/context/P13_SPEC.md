# Stage P13 spec: Android widget, quick add, calendar permission, first-import plan (2026-10-25)

Plan item: PATH_FORWARD P13. Owner decisions (`NEXT_DECISIONS.md`): the widget shows "Safe to spend today" **with the amount**; no new packages. App + Android only; no core or schema change.

## 1. Home-screen widget (Android)
- A native `AppWidgetProvider` (`SafeTodayWidget.kt`) with a small RemoteViews layout (`res/layout/widget_safe_today.xml`, `res/xml/widget_safe_today_info.xml`, min 2×1 cells, resizable horizontally): eyebrow "SAFE TO SPEND TODAY", the amount, and a muted line ("Over the plan" / "to 10 Nov" / "Open the app to update" when stale > 1 day). Ledger colours (paper/ink), follows system dark mode. Tap opens the app (Today).
- **Content only:** the already-formatted amount string, the status word and the date it was computed. Never payments, names, merchants, balances or the key. Nothing is shown before a wallet exists ("Budget Wallet · set up in the app").
- Data path: Dart → new channel `budget_wallet/widget` method `update({amount, status, date})` → native `SharedPreferences` (file `bw_widget`, app-private) → `AppWidgetManager.updateAppWidget`. The controller calls it after every `reload()` whose Today numbers changed, on resume and at day change (debounced; Android only; failures logged as `widget.updateFailed`, never thrown). On "Forget"/join another wallet the widget is cleared.
- Logs: `widget.update {changed}` only.

## 2. Quick-add shortcut
- Static shortcut (`res/xml/shortcuts.xml`, registered via `<meta-data android:name="android.app.shortcuts">` on the launcher activity): "Add expense" (short label "Add"), icon from the existing app icon set (a plain vector `ic_shortcut_add.xml`), intent `ACTION_VIEW` with extra `bw.action=addExpense` to MainActivity.
- MainActivity forwards the action through the channel (`getInitialAction()` at start, `onNewIntent` → `action` event). The app opens the Add expense sheet once the wallet is open (if locked/onboarding: ignored). Logs `shortcut.used`.

## 3. Calendar without WRITE_CALENDAR
- Replace `device_calendar_plus` with the app's own channel `budget_wallet/calendar` (Kotlin, `ContentResolver` on `CalendarContract.Calendars` and `CalendarContract.Instances` for [from, to], read only): `hasPermission`, `requestPermission` (READ_CALENDAR via the activity's permission request), `calendars` (id, name, account, colour), `events(ids, from, to)` (uid/id, title, start, end, all-day, status, notes) mapped by the existing `calendarEventsFrom` shape.
- `AndroidCalendars` keeps the `CalendarSource` interface; remove the plugin from `pubspec.yaml`, remove `WRITE_CALENDAR` (and its comment) from the manifest; READ_CALENDAR stays. Cancelled events still dropped.
- Tests: a mocked channel (pattern `secure_key_test.dart`) for calendars/events/permission; `android_hardening_test.dart` asserts WRITE_CALENDAR is gone.

## 4. Plan suggestion after the first import
- After an import that brought the wallet's first bank rows (or when `planProposalList()` becomes non-empty for the first time), the import flow shows a "Looks right?" sheet with the proposals (salary, payday, rent, loan, subs, plan lines; basis sentence each) and Accept all / Choose… / Not now — the same actions as Plan › Suggestions. Shown once per wallet (device-local `planSuggestShown`); Plan › Suggestions stays.

## 5. Tests
- Widget channel: update payload has only amount/status/date (no other fields), called after reload when the hero changes, not when unchanged; cleared on forget; never on non-Android.
- Shortcut: initial action and a later `action` event open the Add expense sheet; ignored during onboarding.
- Calendar channel mocks; manifest check; existing future_spending tests green.
- First-import sheet: shown once after the first import with proposals; Accept writes the settings; Not now hides it; not shown again.
- Kotlin compiles in `tools/build.sh apk`; `tools/emulator.sh` screens still pass (the widget itself is checked by the owner on the phone).
