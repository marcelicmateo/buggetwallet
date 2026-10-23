part of 'repo.dart';

/// The settings row id of merchant [pattern] (schema 8): `pattern:` + the first 16 hex characters of the SHA-256 of
/// its UTF-8 bytes. The same pattern added on two devices is one row, and the id does not show the pattern. It is not
/// safe in a log: an unsalted hash of a short pattern is reversed with a word list, so problems with these rows are
/// logged under the key `merchantPatterns` (budget rows under `categoryBudgets`).
String merchantPatternId(String pattern) => '${WalletSettings.patternPrefix}${sha256Hex(utf8.encode(pattern)).substring(0, 16)}';

/// The settings row id of [category]'s monthly budget (schema 8).
String _budgetId(String category) => '${WalletSettings.budgetPrefix}$category';

/// The key a settings problem is logged under: a per-key row by its map's name, never its id.
String _logKey(String key) => key.startsWith(WalletSettings.patternPrefix)
    ? 'merchantPatterns'
    : (key.startsWith(WalletSettings.budgetPrefix) ? 'categoryBudgets' : key);

bool _perKeySetting(String key) =>
    key == 'categoryBudgets' ||
    key == 'merchantPatterns' ||
    key.startsWith(WalletSettings.budgetPrefix) ||
    key.startsWith(WalletSettings.patternPrefix);

/// [WalletRepo.settings]: the stored settings, validated by [WalletSettings.fromMap]. Category budgets and merchant
/// patterns come from their per-key rows. The legacy `categoryBudgets` / `merchantPatterns` map rows (schema 7 and
/// older; migrated once by `_migrate`) only fill in entries that have no row at all, live or removed: an old backup
/// restored here, or an entry an older build added after this device migrated. An entry with a row never reads the
/// legacy map again, so a removed budget stays removed.
WalletSettings _readSettings(CommonDatabase db) {
  final m = <String, Object?>{};
  final rowIds = <String>{}; // per-key rows, live or removed
  for (final r in db.select('SELECT id, value, deleted FROM settings')) {
    final k = r['id'] as String, v = r['value'];
    if (k.startsWith(WalletSettings.budgetPrefix) || k.startsWith(WalletSettings.patternPrefix)) rowIds.add(k);
    if (r['deleted'] != 0 || v is! String) continue;
    try {
      m[k] = jsonDecode(v);
    } on FormatException {
      // A damaged value: that setting falls back to its default. The key only, never the value; once per value. A
      // per-key row is logged under its map's key: a pattern id is a hash a word list reverses.
      logInvalidSetting(_logKey(k), 'json:$v');
    }
  }
  if (m['categoryBudgets'] case final Map<String, Object?> legacy) {
    m.remove('categoryBudgets');
    for (final MapEntry(:key, :value) in legacy.entries) {
      final id = _budgetId(key);
      if (!rowIds.contains(id)) m[id] = value;
    }
  }
  if (m['merchantPatterns'] case final List<Object?> legacy) {
    m.remove('merchantPatterns');
    var next = 0;
    for (final MapEntry(:key, :value) in m.entries) {
      if (!key.startsWith(WalletSettings.patternPrefix)) continue;
      if (value case {'order': final int o} when o >= next) next = o + 1;
    }
    for (final p in legacy) {
      if (p is! List || p.length != 2) continue;
      final id = merchantPatternId(p[1].toString());
      if (rowIds.contains(id) || m.containsKey(id)) continue;
      m[id] = {'category': p[0].toString(), 'pattern': p[1].toString(), 'order': next++};
    }
  }
  return WalletSettings.fromMap(m);
}

/// [WalletRepo.updateSettings]: whole-value settings, one row per key. `categoryBudgets`, `merchantPatterns` and the
/// per-key rows are refused with an [ArgumentError] (use `setCategoryBudget`, `setMerchantPattern`,
/// `removeMerchantPattern`): a whole map written by one device would overwrite another device's edit of a different
/// entry. Values are validated when read ([WalletSettings.fromMap]).
List<(String, String, Map<String, Object?>)> _settingChanges(Map<String, Object?> changes) {
  for (final k in changes.keys) {
    if (_perKeySetting(k)) throw ArgumentError.value(k, 'changes', 'a per-key setting; use setCategoryBudget or setMerchantPattern');
  }
  return [
    for (final MapEntry(:key, :value) in changes.entries)
      (
        'setting',
        key,
        {
          'value': jsonEncode(value),
          'deleted': 0,
        }
      )
  ];
}

/// The per-key writes of schema 8 (one row per category budget and per merchant pattern; the row shapes are on
/// [WalletSettings.budgetPrefix]) and their migration.
extension WalletRepoSettings on WalletRepo {
  /// Sets [category]'s monthly budget to [cents], or removes it when null. Throws [ArgumentError] for a category that
  /// is not a spending one ([isSpendingCategory]) or cents outside 0..[WalletSettings.maxBudget]. Writes nothing when
  /// the budget is already that value.
  void setCategoryBudget(String category, int? cents) {
    if (!isSpendingCategory(category)) throw ArgumentError.value(category, 'category', 'not a spending category');
    if (cents != null && (cents < 0 || cents > WalletSettings.maxBudget)) throw ArgumentError('budget out of range');
    if (settings().categoryBudgets[category] == cents) return;
    _write([
      ('setting', _budgetId(category), cents == null ? {'value': null, 'deleted': 1} : {'value': jsonEncode(cents), 'deleted': 0})
    ]);
  }

  /// Adds merchant [pattern] (a case-insensitive regex matched against the lower-cased description) for [category],
  /// or moves an existing one to [category]. A new pattern is matched after every other one (`order` = the largest
  /// live order + 1); an existing one keeps its place. Throws [ArgumentError] for an unknown category, an empty
  /// pattern or one that does not compile (the message never quotes the pattern). Writes nothing when unchanged.
  void setMerchantPattern(String category, String pattern) {
    if (!categories.containsKey(category)) throw ArgumentError.value(category, 'category', 'unknown category');
    if (pattern.trim().isEmpty) throw ArgumentError('empty pattern');
    try {
      RegExp(pattern, caseSensitive: false);
    } on FormatException catch (e) {
      logEvent(_log, Level.INFO, 'settings.badPattern', {'offset': e.offset, 'length': pattern.length});
      throw ArgumentError('pattern does not compile');
    }
    final id = merchantPatternId(pattern);
    int? order;
    var next = 0;
    for (final r in db.select('SELECT id, value FROM settings WHERE deleted = 0 AND id LIKE ?', ['${WalletSettings.patternPrefix}%'])) {
      final v = r['value'];
      final Object? row;
      try {
        row = v is String ? jsonDecode(v) : null;
      } on FormatException {
        logInvalidSetting('merchantPatterns', 'json:$v'); // the key only, once per value
        continue;
      }
      if (row case {'category': final String c, 'order': final int o}) {
        if (o >= next) next = o + 1;
        if (r['id'] == id) {
          if (c == category) return;
          order = o;
        }
      }
    }
    _write([
      (
        'setting',
        id,
        {
          'value': jsonEncode({'category': category, 'pattern': pattern, 'order': order ?? next}),
          'deleted': 0
        }
      )
    ]);
  }

  /// Removes merchant [pattern] (whatever its category). Writes nothing when it is not set.
  void removeMerchantPattern(String pattern) {
    if (!settings().merchantPatterns.any((p) => p[1] == pattern)) return;
    _write([
      ('setting', merchantPatternId(pattern), {'value': null, 'deleted': 1})
    ]);
  }

  /// Schema 8 (H3): the legacy `categoryBudgets` / `merchantPatterns` maps become one row per entry. An entry whose id
  /// already has a settings row, live or removed (another device's per-key write that arrived first), is skipped: the
  /// row is newer information than the map, and [_readSettings] ignores the map for it too, so the migration never
  /// changes what is shown. The other entries are written with the clock of the legacy row's `value`, not a fresh one,
  /// and queued in the outbox (so they sync): every device migrating the same map writes the same ops. Patterns get
  /// `order` after the largest live one, in map order, as the read fallback does. Everything is one transaction (a crash
  /// midway leaves schema 7 and no rows, and the next open starts over). A legacy row without a clock goes through
  /// [_write] after it. The legacy rows stay as they are, so an older build keeps reading its map. Returns the number of
  /// rows written.
  int _migratePerKeySettings() {
    final have = <String>{
      for (final r in db.select("SELECT id FROM settings WHERE id LIKE 'budget:%' OR id LIKE 'pattern:%'")) r['id'] as String
    };
    var next = 0;
    for (final r in db.select("SELECT value FROM settings WHERE deleted = 0 AND id LIKE 'pattern:%'")) {
      final v = r['value'];
      if (v is! String) continue;
      try {
        if (jsonDecode(v) case {'order': final int o} when o >= next) next = o + 1;
      } on FormatException {
        logInvalidSetting('merchantPatterns', 'json:$v'); // the key only, once per value
      }
    }
    final ops = <(String, Map<String, Object?>)>[]; // legacy key, the per-key changes made from it
    for (final key in const ['categoryBudgets', 'merchantPatterns']) {
      final r = db.select('SELECT value FROM settings WHERE id = ? AND deleted = 0', [key]).firstOrNull;
      final v = r?['value'];
      if (v is! String) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(v);
      } on FormatException {
        logInvalidSetting(key, 'json:$v');
        continue;
      }
      final st = WalletSettings.fromMap({key: decoded});
      final changes = <String, Object?>{};
      if (key == 'categoryBudgets') {
        for (final MapEntry(key: c, value: cents) in st.categoryBudgets.entries) {
          if (!have.contains(_budgetId(c))) changes[_budgetId(c)] = jsonEncode(cents);
        }
      } else {
        for (final [c, p] in st.merchantPatterns) {
          final id = merchantPatternId(p);
          // A repeated pattern: the first one matched anyway. One with a row: that row wins.
          if (changes.containsKey(id) || have.contains(id)) continue;
          changes[id] = jsonEncode({'category': c, 'pattern': p, 'order': next++});
        }
      }
      if (changes.isNotEmpty) ops.add((key, changes));
    }
    final fresh = <(String, String, Map<String, Object?>)>[];
    var rows = 0;
    _tx(() {
      for (final (key, changes) in ops) {
        rows += changes.length;
        final hlc = db.select("SELECT hlc FROM clocks WHERE entity = 'setting' AND id = ? AND field = 'value'", [key]).firstOrNull?['hlc'];
        for (final MapEntry(:key, :value) in changes.entries) {
          if (hlc is! String) {
            fresh.add(('setting', key, {'value': value, 'deleted': 0}));
            continue;
          }
          final op = Op('setting', key, {'value': value, 'deleted': 0}, hlc);
          _apply(op);
          db.execute('INSERT INTO outbox(op) VALUES(?)', [jsonEncode(op.toJson())]);
        }
      }
    });
    // Runs inside open (schema 8 migration): internal, so a device clock that went back cannot stop the wallet opening.
    _writeInternal(fresh);
    return rows;
  }
}
