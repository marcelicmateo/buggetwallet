# Setting up Budget Wallet

## 1. Install the app

**Android:** open the latest successful run of the `ci` workflow on GitHub (Actions tab), download `budget-wallet-android`, unzip, open `app-release.apk` on the phone and allow installing from this source.

**Linux:** download `budget-wallet-linux`, unzip, run `budget_wallet`.

**Windows / macOS / iPhone:** build from source on that machine:

```
cd app
flutter pub get
flutter run --release          # or: flutter build windows / macos / ipa
```

iPhone builds need Xcode and an Apple ID (free accounts can install for 7 days at a time).

## 2. First device

Open the app → **Start a new wallet**. Then Plan → **Show wallet key** and keep the key somewhere safe (a password manager). Without it, the encrypted sync files cannot be read.

## 3. Sync with Syncthing

1. Install Syncthing on every device: Syncthing (Windows/macOS/Linux), Syncthing-Fork (Android), Möbius Sync (iPhone).
2. Create one shared folder, e.g. `Documents/BudgetWallet` on Android and `~/BudgetWallet` on the computer, and share it between the devices in Syncthing.
3. In the app: Plan → **Choose folder** and pick that folder. On Android also tap **Allow file access**. On iPhone tap **Use the app folder** and add that folder in Möbius Sync.
4. On each additional device: **Join my wallet from another device**, enter the key, then choose the same folder.

The app syncs when it opens, every 2 minutes while open, and a few seconds after each change.

## 4. Bring in your history

Plan → **Choose files** and select the PBZ (.xls) and Revolut (.xlsx/.csv) exports. Re-importing the same period is safe.
