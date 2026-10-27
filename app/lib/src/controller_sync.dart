// Wallet key and sync in the controller: create, join and unlock a wallet, the key backup prompt and clipboard, the relay address
// and the sync runs. A `part` of controller.dart so it can use the cache, the loggers and `_changed`.
//
// Privacy: logs carry action words, counts and enum words only; never the key, a relay address, a path or a file name.
part of 'controller.dart';

extension WalletSync on WalletController {
  // ---------- wallet / key ----------

  /// Joins with the wallet [text] key. [relay] (optional, can be set later in Plan) is the relay address; the first sync follows.
  /// [keyWritten]: the key is already in the key store ([joinAnotherWallet] wrote it before setting the old database aside).
  Future<void> joinWallet(String text, {String? passphrase, Uri? relay, bool keyWritten = false}) async {
    final k = await VaultKey.parse(text); // errors are logged by the caller (never the text)
    final r = relay == null ? null : WalletController.parseRelayAddress(relay.toString());
    if (relay != null && r == null) throw const FormatException('Not a relay address');
    // No key was stored but an unkeyed (plaintext) file exists: it belongs to no wallet we can name, and opening it with this key
    // would convert it and merge its data into the joined wallet. Set it aside (before the key is written, as in create).
    if (_dbPending && hasUnopenedDb && await deps.dbIsPlaintext()) await _setAsideUnopened();
    if (!keyWritten) await deps.keyWriter(k, passphrase: passphrase);
    if (_dbPending) await _openFileDb(k, freshId: true);
    key = k;
    repo.setLocalValue('keyBackupConfirmed', today()); // they typed the key in, so they have it
    if (r != null) {
      repo.setLocalValue('relayUrl', r.toString());
      relayUrl = r;
    }
    logEvent(_log, Level.INFO, 'wallet.join', {'relay': r != null});
    notifyListeners();
    await syncNow(trigger: 'join');
  }

  /// Plan › "Join another wallet…": joins the wallet with [text] while this one is open. Checked first, nothing touched on a
  /// failure: the key parses, the relay is an address, this wallet's own key was saved ([KeyNotSaved]) and [text] is not this wallet's
  /// key ([WalletAlreadyOpen]). Then, in this order: a last sync of pending changes (after that no sync starts: `_joining`); the old
  /// key is stored in a second slot (`KeyStore.writeAside`); a "join pending" marker (relay, fresh device id; a side file, never the
  /// database); the new key is written; the database is closed and moved aside (`wallet.db.unopened-<date>`, `db.setAside`, never
  /// deleted); the join goes on as on a first run; the marker is cleared. A crash on the way: the next start finds the marker and a
  /// key that opens no `wallet.db` and finishes the join from it (see [load]). Not on the web (no set-aside path).
  /// The old key never leaves the device while the old database exists: a slot is removed only once the old wallet is open again.
  Future<void> joinAnotherWallet(String text, {String? passphrase, Uri? relay}) async {
    final k = await VaultKey.parse(text);
    if (relay != null && WalletController.parseRelayAddress(relay.toString()) == null) throw const FormatException('Not a relay address');
    final current = key;
    if (current != null && await current.toText() == await k.toText()) throw const WalletAlreadyOpen();
    if (!_dbPending && !keyBackupConfirmed) throw const KeyNotSaved();
    final written = !_dbPending;
    if (written) {
      await clearHomeWidget(); // the old wallet's number must not stay on the home screen
      await _setAsideOpenWallet(k, passphrase, relay);
      await clearHomeWidget(); // a reload on the way may have given it again
    }
    try {
      await joinWallet(text, passphrase: passphrase, relay: relay, keyWritten: written);
    } catch (e) {
      // The old wallet is already set aside: show first-run onboarding, so nothing looks open that is not. The marker stays: the
      // next start finishes the join.
      key = null;
      notifyListeners();
      await clearHomeWidget();
      rethrow;
    }
    await _clearJoinMarker();
  }

  /// Ends the running sync and sends what is still pending, then stores the old key aside, writes the marker and [newKey], closes
  /// the open database and moves it aside; the controller then runs on the in-memory placeholder like before a first key. A failure
  /// puts the old key back and opens the old database again, then throws.
  Future<void> _setAsideOpenWallet(VaultKey newKey, String? passphrase, Uri? relay) async {
    _syncTimer?.cancel();
    _dayTimer?.cancel();
    _debounce?.cancel();
    _persistTimer?.cancel();
    await _syncRun?.future;
    if (relayUrl != null && repo.pendingOps().isNotEmpty) await syncNow(quiet: true, trigger: 'beforeJoin');
    _joining = true;
    try {
      await _setAsideJoining(newKey, passphrase, relay);
    } finally {
      _joining = false;
    }
    _startAutoSync();
  }

  Future<void> _setAsideJoining(VaultKey newKey, String? passphrase, Uri? relay) async {
    while (_syncRun != null) {
      await _syncRun!.future; // one that began before the flag was set
    }
    await persistNow();
    final stamp = isoDate(_clock());
    final oldKey = key!;
    String? slot;
    try {
      slot = await deps.keyAsideWriter(stamp, oldKey);
      await deps.joinMarkerWriter(_joinMarkerText(relay));
      await deps.keyWriter(newKey, passphrase: passphrase);
    } catch (e, st) {
      logError(_log, 'db.setAside.keyFailed', e, st, level: Level.SEVERE);
      if (slot != null) {
        // Put the old key back first; only when that worked is the slot (and the marker) given up.
        try {
          await deps.keyWriter(oldKey);
          await _removeAsideKey(slot);
          await _clearJoinMarker();
        } catch (e2, st2) {
          logError(_log, 'db.setAside.keyRestoreFailed', e2, st2, level: Level.SEVERE);
        }
      }
      _startAutoSync();
      rethrow;
    }
    await _syncRun?.future; // nothing may still be running when the repo closes
    final old = repo;
    _db = null;
    repo = WalletRepo.inMemory();
    _dbPending = true;
    old.close();
    try {
      await deps.dbSetAside(stamp);
    } catch (e, st) {
      logError(_log, 'db.setAside.failed', e, st, level: Level.SEVERE);
      try {
        // A partial move (wallet.db gone) is not "reopened" as a new empty wallet.db.
        if (!await deps.dbExists()) throw StateError('wallet.db is gone after a partial set-aside');
        await deps.keyWriter(oldKey);
        await _openFileDb(oldKey, asideOnMismatch: false);
        await _removeAsideKey(slot);
        await _clearJoinMarker();
      } catch (e2, st2) {
        logError(_log, 'db.reopenFailed', e2, st2, level: Level.SEVERE);
        // Nothing is open: first-run onboarding says an older wallet is on this device. The slot stays (the old key is the only way
        // to open that copy); the marker goes, so the next start does not build a new wallet next to what is left.
        hasUnopenedDb = true;
        key = null;
        try {
          await deps.keyWriter(oldKey);
        } catch (e3, st3) {
          logError(_log, 'db.keyRestoreFailed', e3, st3, level: Level.SEVERE);
        }
        await _clearJoinMarker();
        notifyListeners();
      }
      _startAutoSync();
      rethrow;
    }
    logEvent(_log, Level.WARNING, 'db.setAside', {'reason': 'join'});
    hasUnopenedDb = false;
    _resetSyncStatus();
    lastImport = const [];
  }

  /// The small device-local "join pending" note: the relay address (if any) and the device id the new wallet will use. Never the
  /// key, never in the database.
  String _joinMarkerText(Uri? relay) => jsonEncode({'v': 1, 'relay': relay?.toString(), 'id': WalletRepo.newDeviceId()});

  Future<void> _clearJoinMarker() async {
    try {
      await deps.joinMarkerClearer();
    } catch (e, st) {
      logError(_log, 'join.markerClearFailed', e, st);
    }
  }

  Future<void> _removeAsideKey(String slot) async {
    try {
      await deps.keyAsideRemover(slot);
    } catch (e, st) {
      logError(_log, 'db.setAside.slotFailed', e, st);
    }
  }

  /// Nothing of the old wallet's sync status, devices or errors may show for the next wallet (also when it uses the same relay).
  void _resetSyncStatus() {
    relayUrl = null;
    sync.reset();
    _relayFollowUp = false;
  }

  // ---------- key backup prompt (see app/CLAUDE.md, Sync) ----------
  // Device-local values (never synced): `keyBackupConfirmed` (date) and `keyBackupSnoozedUntil` (date). Logs say `key.backup`
  // with an action word only; never the key or any part of it, also not the characters typed to confirm.

  /// The owner confirmed (or, on a joined device, typed in) the key.
  bool get keyBackupConfirmed => repo.localValue('keyBackupConfirmed') != null;

  /// Show Today's "Save your wallet key" row: a key exists, it is not confirmed, and "Later" is not in force.
  bool get keyBackupRowVisible {
    if (!hasWallet || keyBackupConfirmed) return false;
    final until = repo.localValue('keyBackupSnoozedUntil');
    return until == null || today().compareTo(until) >= 0;
  }

  /// Today is built once per [dataVersion]: the row appears or goes with a new version (no data was reloaded).
  void _keyBackupChanged() {
    dataVersion++;
    notifyListeners();
  }

  /// Logs that the save-key screen was shown.
  void keyBackupShown() => logEvent(_key, Level.INFO, 'key.backup', {'action': 'shown'});

  /// Whether the owner hid the first-run panel on Today for exactly these open [steps] (device-local); it is then one line.
  /// A different set of open steps (a new one appeared, or one was done) shows the panel open again.
  bool setupCollapsedFor(List<String> steps) => repo.localValue('setupCollapsed') == steps.join(',');

  void setSetupCollapsed(bool v, List<String> steps) {
    repo.setLocalValue('setupCollapsed', v ? steps.join(',') : null);
    _keyBackupChanged();
  }

  /// Copies the key; 60 seconds later the clipboard is emptied unless it is readable and holds something else.
  /// (Android 10+ shows a background app an empty clipboard, so "null" counts as "still ours".) If the app is in the
  /// background then, the clear waits for the next resume; disposing the controller clears at once.
  Future<void> copyKeyBackup() async {
    final t = await keyText();
    if (t.isEmpty) return;
    await copySensitive(t);
    logEvent(_key, Level.INFO, 'key.backup', {'action': 'copied'});
  }

  /// Puts [text] on the clipboard and empties it again after [keyClipboardLife] (the rules of [copyKeyBackup]); a later copy
  /// replaces the pending clear. Used for the wallet key and the pay-sheet fields.
  Future<void> copySensitive(String t) async {
    await deps.clipboardWrite(t);
    _clipboardTimer?.cancel();
    _resumeClear?.dispose();
    _resumeClear = null;
    _pendingClipboardKey = t;
    _clipboardTimer = Timer(WalletController.keyClipboardLife, () {
      _clipboardTimer = null;
      final state = WidgetsBinding.instance.lifecycleState;
      if (state != null && state != AppLifecycleState.resumed) {
        _resumeClear?.dispose();
        _resumeClear = AppLifecycleListener(onResume: () {
          _resumeClear?.dispose();
          _resumeClear = null;
          _clearClipboardKey();
        });
        return;
      }
      _clearClipboardKey();
    });
  }

  /// Empties the clipboard unless it can be read and holds something other than the copied key.
  Future<void> _clearClipboardKey() async {
    final t = _pendingClipboardKey;
    if (t == null) return;
    _pendingClipboardKey = null;
    try {
      String? now;
      var readable = true;
      try {
        now = await deps.clipboardRead();
      } catch (e, st) {
        readable = false;
        logError(_key, 'key.backup.clipboard', e, st, fields: {'type': e.runtimeType.toString()});
      }
      if (readable && now != null && now != t) return;
      await deps.clipboardWrite('');
    } catch (e, st) {
      logError(_key, 'key.backup.clipboard', e, st, fields: {'type': e.runtimeType.toString()});
    }
  }

  /// Upper case, spaces and dashes dropped, a typed 0 read as the letter O (the key has no zero), like `VaultKey.parse`.
  static String _plainKey(String s) => s.toUpperCase().replaceAll(RegExp(r'[\s-]'), '').replaceAll('0', 'O');

  /// Do [typed] (spaces and dashes ignored, any case) equal the last 4 characters of the key? Only then it is confirmed.
  Future<bool> confirmKeyBackup(String typed) async {
    final k = _plainKey(await keyText());
    final n = _plainKey(typed);
    if (k.isEmpty || n.length != 4 || !k.endsWith(n)) return false;
    repo.setLocalValue('keyBackupConfirmed', today());
    repo.setLocalValue('keyBackupSnoozedUntil', null);
    logEvent(_key, Level.INFO, 'key.backup', {'action': 'confirmed'});
    _keyBackupChanged();
    return true;
  }

  /// Web: opens the key stored in this browser with [passphrase]. Throws [WrongPassphrase]; the typed text is never logged.
  Future<void> unlock(String passphrase) async {
    final k = await deps.unlocker(passphrase);
    if (_dbPending) {
      try {
        await _openFileDb(k, asideOnMismatch: false);
      } on WalletDbKeyException {
        // The stored key does not open the stored database: keep the file, go to onboarding (create sets it aside).
        logEvent(_log, Level.WARNING, 'wallet.unlock', {'keyMismatch': true});
        hasUnopenedDb = true;
        locked = false;
        notifyListeners();
        return;
      }
    }
    key = k;
    locked = false;
    logEvent(_log, Level.INFO, 'wallet.unlock');
    notifyListeners();
    await syncNow(trigger: 'unlock');
  }

  /// Web "Forget this browser": deletes the database and the stored key, then starts over with an empty wallet and no key
  /// (the app shows onboarding). Throws the first failure after the state was reset.
  Future<void> forgetBrowser() async {
    logEvent(_log, Level.INFO, 'wallet.forget');
    _syncTimer?.cancel();
    _dayTimer?.cancel();
    _debounce?.cancel();
    _persistTimer?.cancel();
    Object? failure;
    StackTrace? failureStack;
    try {
      final db = _db;
      if (db != null) {
        await db.forget();
      } else {
        repo.close();
      }
    } catch (e, st) {
      logError(_log, 'wallet.forget.dbFailed', e, st, level: Level.SEVERE);
      failure = e;
      failureStack = st;
    }
    try {
      await deps.keyForgetter();
    } catch (e, st) {
      logError(_log, 'wallet.forget.keyFailed', e, st, level: Level.SEVERE);
      if (failure == null) {
        failure = e;
        failureStack = st;
      }
    }
    key = null;
    locked = false;
    // No key, so no database: back to the in-memory placeholder until a wallet is created or joined (a new file system then).
    _db = null;
    repo = WalletRepo.inMemory();
    _dbPending = true;
    hasUnopenedDb = false;
    relayUrl = null;
    sync.reset();
    lastImport = const [];
    reload();
    _startAutoSync();
    if (failure != null) Error.throwWithStackTrace(failure, failureStack ?? StackTrace.current);
  }

  /// Sets (or, with null, clears) the relay address, device-local, then syncs. Throws [FormatException] for a bad address
  /// (the address is never logged: only `set` / `unset`).
  Future<void> setRelay(Uri? url) async {
    final u = url == null ? null : WalletController.parseRelayAddress(url.toString());
    if (url != null && u == null) throw const FormatException('Not a relay address');
    repo.setLocalValue('relayUrl', u?.toString());
    relayUrl = u;
    // What the screen shows belongs to the old relay: clear it at once (a run in flight for the old relay is dropped below).
    sync.reset(keepLastSync: true);
    repo.setLocalValue(WalletController._noticeRelayChanged, null);
    repo.setLocalValue(WalletController._noticeIdInUse, null);
    _relayFollowUp = u != null && syncing; // a run is going: exactly one follow-up for the new address when it ends
    logEvent(_sync, Level.INFO, 'sync.relay', {'set': u != null}); // never the address
    notifyListeners();
    if (u != null) await syncNow(trigger: 'relay');
  }

  /// "Test connection": returns when a relay answers at [url] and speaks this build's API. Throws [TransportException]
  /// (`unreachable`, `newerApi`, …). Nothing about the address is logged.
  Future<void> testRelay(Uri url) async {
    try {
      await deps.healthCheck(url);
      logEvent(_sync, Level.INFO, 'sync.health', {'ok': true});
    } on TransportException catch (e) {
      logEvent(_sync, Level.INFO, 'sync.health', {'ok': false, 'failure': e.failure.name});
      rethrow;
    }
  }

  /// Changes when wallet data changes: every data write (local or applied from a peer) records its field clock. Bookkeeping
  /// a failed run still makes (the next file number in `meta`, the outbox) doesn't count.
  (WalletRepo, int) _dataMark() => (repo, repo.dataVersion);

  void _startAutoSync() {
    _dayTimer?.cancel();
    _syncTimer?.cancel();
    _dayTimer = Timer.periodic(const Duration(minutes: 2), (_) => checkDay());
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (_) => syncNow(quiet: true, trigger: 'timer'));
    scheduleMicrotask(() => syncNow(quiet: true, trigger: 'startup'));
  }
}
