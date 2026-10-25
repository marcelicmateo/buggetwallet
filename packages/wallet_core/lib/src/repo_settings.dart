part of 'repo.dart';

/// The settings row id of [category]'s monthly budget (schema 8).
String _budgetId(String category) => '${WalletSettings.budgetPrefix}$category';

/// The key a settings problem is logged under: a per-key row by its map's name, never its id.
String _logKey(String key) => key.startsWith(WalletSettings.patternPrefix)
    ? 'merchantPatterns'
    : (key.startsWith(WalletSettings.budgetPrefix)
        ? 'categoryBudgets'
        : (key.startsWith(WalletSettings.planPrefix) ? 'planLines' : (key.startsWith(WalletSettings.csvMapPrefix) ? 'csvmap' : key)));

bool _perKeySetting(String key) =>
    key == 'categoryBudgets' ||
    key == 'merchantPatterns' ||
    key == 'planLines' ||
    key == 'csvMappings' ||
    key.startsWith(WalletSettings.csvMapPrefix) ||
    key.startsWith(WalletSettings.planPrefix) ||
    key.startsWith(WalletSettings.budgetPrefix) ||
    key.startsWith(WalletSettings.patternPrefix);

/// [WalletRepo.settings]: the stored settings, validated by [WalletSettings.fromMap]. Category budgets and merchant
/// patterns come from their per-key rows. The legacy `categoryBudgets` / `merchantPatterns` map rows (schema 7 and
/// older; migrated once by `_migrate`) only fill in entries that have no row at all, live or removed: an old backup
/// restored here, or an entry an older build added after this device migrated. An entry with a row never reads the
/// legacy map again, so a removed budget stays removed.
WalletSettings _readSettings(CommonDatabase db, {CategoryTable? table}) {
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
  return WalletSettings.fromMap(m, table: table);
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
  /// is not a live top-level spending one ([CategoryTable.isSpending]; budgets are set on top-level categories only,
  /// children roll up into them) or cents outside 0..[WalletSettings.maxBudget]. Writes nothing when the budget is
  /// already that value.
  void setCategoryBudget(String category, int? cents) {
    final table = categoryTable();
    if (!table.isSpending(category)) throw ArgumentError.value(category, 'category', 'not a spending category');
    if (table.parentOf(category) != null) {
      throw ArgumentError.value(category, 'category', 'a subcategory has no budget of its own; set it on its parent');
    }
    if (cents != null && (cents < 0 || cents > WalletSettings.maxBudget)) throw ArgumentError('budget out of range');
    if (_readSettings(db, table: table).categoryBudgets[category] == cents) return;
    _write([
      ('setting', _budgetId(category), cents == null ? {'value': null, 'deleted': 1} : {'value': jsonEncode(cents), 'deleted': 0})
    ]);
  }

  /// Sets the plan line of custom fixed category [categoryId] (P1, [WalletSettings.planLines]) to [cents] a month, or
  /// removes it when null. Throws [ArgumentError] when the category has no plan line ([CategoryTable.hasPlanLine]: a
  /// live top-level custom category of kind fixed) or cents outside 0..[WalletSettings.maxAmount]. Writes nothing when
  /// the line already has that value.
  void setPlanLine(String categoryId, int? cents) {
    final table = categoryTable();
    if (!table.hasPlanLine(categoryId)) {
      throw ArgumentError.value(categoryId, 'categoryId', 'only an own main category of kind fixed has a plan line');
    }
    if (cents != null && (cents < 0 || cents > WalletSettings.maxAmount)) throw ArgumentError('plan line out of range');
    if (_readSettings(db, table: table).planLines[categoryId] == cents) return;
    _write([
      (
        'setting',
        '${WalletSettings.planPrefix}$categoryId',
        cents == null ? {'value': null, 'deleted': 1} : {'value': jsonEncode(cents), 'deleted': 0}
      )
    ]);
    logEvent(_log, Level.INFO, 'settings.planLine', {'set': cents != null});
  }

  /// Saves the owner's column mapping for CSV shape [shapeId] (P12, [WalletSettings.csvMappings]): the synced row
  /// `csvmap:<shapeId>` holds [mapping]'s JSON, so every device imports that shape the same way. Adding and changing
  /// (a rename, another column) are the same call; the Undo of a removal sets it again. Throws [ArgumentError] for a
  /// shape id that is not 16 lower-case hex characters or a mapping with a problem of its own (the first
  /// [CsvMapping.structureProblems] text, owner-readable). Writes nothing when the stored layout is already that.
  /// Logs `settings.csvMapping {op}` only: never the name or the columns.
  void setCsvMapping(String shapeId, CsvMapping mapping) {
    if (!WalletSettings.csvShapeIdPattern.hasMatch(shapeId)) throw ArgumentError.value(shapeId, 'shapeId', 'not a CSV shape id');
    final problems = mapping.structureProblems();
    if (problems.isNotEmpty) throw ArgumentError(problems.first);
    final old = _storedCsvMapping(shapeId);
    final next = mapping.copyWith(name: mapping.name.trim());
    if (old == next) return;
    _write([
      ('setting', '${WalletSettings.csvMapPrefix}$shapeId', {'value': jsonEncode(next.toJson()), 'deleted': 0})
    ]);
    logEvent(_log, Level.INFO, 'settings.csvMapping', {'op': old == null ? 'add' : 'set'});
  }

  /// Removes the saved layout of [shapeId] (a tombstone, synced). Rows already imported with it keep their source.
  /// Nothing is written when there is no live layout for it.
  void removeCsvMapping(String shapeId) {
    if (_storedCsvMapping(shapeId) == null) return;
    _write([
      ('setting', '${WalletSettings.csvMapPrefix}$shapeId', {'value': null, 'deleted': 1})
    ]);
    logEvent(_log, Level.INFO, 'settings.csvMapping', {'op': 'remove'});
  }

  /// The live, valid layout stored for [shapeId] (one row read, as [WalletSettings.csvMappings] reads it), or null.
  CsvMapping? _storedCsvMapping(String shapeId) {
    final key = '${WalletSettings.csvMapPrefix}$shapeId';
    final v = db.select('SELECT value FROM settings WHERE id = ? AND deleted = 0', [key]).firstOrNull?['value'];
    if (v is! String) return null;
    try {
      return WalletSettings.fromMap({key: jsonDecode(v)}).csvMappings[shapeId];
    } on FormatException {
      return null;
    }
  }

  /// Adds merchant [pattern] for [category], or sets an existing one (same text) to exactly this rule: [category],
  /// [match] and the amount range. [match] is `regex` (a case-insensitive regex matched against the lower-cased
  /// description; the default) or `contains` (a case- and accent-folded substring, 1–60 characters, stored trimmed).
  /// [minCents] / [maxCents] (optional, inclusive, against the absolute amount, 0..[WalletSettings.maxAmount], min ≤ max)
  /// only narrow the text match (P7). A new pattern is matched after every other one (`order` = the largest live order
  /// + 1); an existing one keeps its place. Throws [ArgumentError] for an unknown or deleted category
  /// ([CategoryTable.isLive]), an empty pattern, a regex that does not compile, a `contains` text over 60 characters,
  /// an unknown [match] or a bad range (the message never quotes the pattern). Writes nothing when unchanged.
  void setMerchantPattern(String category, String pattern, {String match = MerchantPattern.regex, int? minCents, int? maxCents}) {
    final text = _checkPattern(category, pattern, match, minCents, maxCents);
    final id = merchantPatternId(text);
    final rows = _patternRows();
    final old = rows[id];
    final next = MerchantPattern(
        id: id,
        category: category,
        pattern: text,
        match: match,
        minCents: minCents,
        maxCents: maxCents,
        order: old?.order ?? _nextOrder(rows));
    if (old != null && _samePattern(old, next)) return;
    _write([_patternWrite(next)]);
    logEvent(_log, Level.INFO, 'settings.pattern', {'op': old == null ? 'add' : 'set', 'match': match, 'range': next.hasRange});
  }

  /// Edits the pattern row [id] (`pattern:<16 hex>`): only the given fields change. The range becomes
  /// `clearRange ? minCents : (minCents ?? old)` and the same for max. A category, match or range change keeps the
  /// row id; a text change is a new id (ids are a hash of the text), so the old row is removed and the new row takes
  /// the same `order`, in one write. Returns the row id after the edit. Throws [ArgumentError] for an unknown or
  /// removed id, a new text another live pattern already has, and everything [setMerchantPattern] refuses. Writes
  /// nothing when unchanged.
  String updateMerchantPattern(String id,
      {String? category, String? pattern, String? match, int? minCents, int? maxCents, bool clearRange = false}) {
    final rows = _patternRows();
    // A legacy-map entry without a row of its own (an older build's add) is edited like a row.
    final old = rows[id] ?? _readSettings(db, table: categoryTable()).patternRules.where((p) => p.id == id).firstOrNull;
    if (old == null) throw ArgumentError.value(id, 'id', 'no such rule');
    final c = category ?? old.category, m = match ?? old.match;
    final lo = clearRange ? minCents : (minCents ?? old.minCents), hi = clearRange ? maxCents : (maxCents ?? old.maxCents);
    final text = _checkPattern(c, pattern ?? old.pattern, m, lo, hi);
    final newId = merchantPatternId(text);
    if (newId != id && (rows.containsKey(newId) || _readSettings(db, table: categoryTable()).patternRules.any((p) => p.id == newId))) {
      throw ArgumentError('a rule with this text already exists');
    }
    final next = MerchantPattern(id: newId, category: c, pattern: text, match: m, minCents: lo, maxCents: hi, order: old.order);
    if (_samePattern(old, next)) return id;
    _write([
      _patternWrite(next),
      if (newId != id) ('setting', id, {'value': null, 'deleted': 1}),
    ]);
    logEvent(_log, Level.INFO, 'settings.pattern', {'op': 'update', 'match': m, 'range': next.hasRange, 'newId': newId != id});
    return newId;
  }

  /// Moves pattern [id] one place up or down in the match order ([WalletSettings.patternRules]): it swaps `order`
  /// with its neighbour (two writes). When any two patterns share an order (a sync of two adds), the whole list is
  /// numbered 0..n-1 in its current order first and then the two swap, in one write (only rows whose order changes),
  /// so one press moves exactly one place. Nothing at the ends. [ArgumentError] for an unknown id.
  void movePattern(String id, MoveDirection direction) {
    final list = [..._readSettings(db, table: categoryTable()).patternRules];
    final i = list.indexWhere((p) => p.id == id);
    if (i < 0) throw ArgumentError.value(id, 'id', 'no such rule');
    final j = direction == MoveDirection.up ? i - 1 : i + 1;
    if (j < 0 || j >= list.length) return;
    final a = list[i], b = list[j];
    final List<MerchantPattern> changed;
    if (list.map((p) => p.order).toSet().length == list.length) {
      changed = [_withOrder(a, b.order), _withOrder(b, a.order)];
    } else {
      list[i] = b;
      list[j] = a;
      changed = [
        for (final (k, p) in list.indexed)
          if (p.order != k) _withOrder(p, k)
      ];
    }
    _write([for (final p in changed) _patternWrite(p)]);
    logEvent(_log, Level.INFO, 'settings.pattern', {'op': 'move', 'writes': changed.length});
  }

  /// Removes merchant [pattern] (whatever its category). Writes nothing when it is not set.
  void removeMerchantPattern(String pattern) {
    if (!settings().merchantPatterns.any((p) => p[1] == pattern)) return;
    _write([
      ('setting', merchantPatternId(pattern), {'value': null, 'deleted': 1})
    ]);
  }

  /// The checked text of a pattern write ([setMerchantPattern]): trimmed for `contains`, as given for a regex.
  String _checkPattern(String category, String pattern, String match, int? minCents, int? maxCents) {
    if (!categoryTable().isLive(category)) throw ArgumentError.value(category, 'category', 'unknown category');
    if (match != MerchantPattern.regex && match != MerchantPattern.contains) throw ArgumentError.value(match, 'match', 'regex or contains');
    if (MerchantPattern.rangeError(minCents, maxCents) case final e?) throw ArgumentError(e);
    if (match == MerchantPattern.regex && (minCents != null || maxCents != null)) throw ArgumentError(MerchantPattern.rangeNeedsContains);
    // Never a rule without text: a range alone would classify on the amount (owner rule).
    if (pattern.trim().isEmpty) throw ArgumentError('empty pattern');
    if (match == MerchantPattern.contains) {
      final t = pattern.trim();
      if (t.length > MerchantPattern.maxContainsLength) throw ArgumentError('text over ${MerchantPattern.maxContainsLength} characters');
      return t;
    }
    final RegExp re;
    try {
      re = RegExp(pattern, caseSensitive: false);
    } on FormatException catch (e) {
      logEvent(_log, Level.INFO, 'settings.badPattern', {'offset': e.offset, 'length': pattern.length});
      throw ArgumentError('pattern does not compile');
    }
    if (MerchantPattern.matchesEverything(re)) throw ArgumentError('the pattern matches every payment');
    return pattern;
  }

  /// The live pattern rows by id, as stored (no legacy-map entries). A damaged value is skipped (logged by key).
  Map<String, MerchantPattern> _patternRows() {
    final out = <String, MerchantPattern>{};
    for (final r in db.select('SELECT id, value FROM settings WHERE deleted = 0 AND id LIKE ?', ['${WalletSettings.patternPrefix}%'])) {
      final v = r['value'];
      final Object? row;
      try {
        row = v is String ? jsonDecode(v) : null;
      } on FormatException {
        logInvalidSetting('merchantPatterns', 'json:$v'); // the key only, once per value
        continue;
      }
      final id = r['id'] as String;
      if (MerchantPattern.read(id, row).$1 case final p?) out[id] = p;
    }
    return out;
  }

  static int _nextOrder(Map<String, MerchantPattern> rows) => rows.values.fold(0, (n, p) => p.order >= n ? p.order + 1 : n);

  static bool _samePattern(MerchantPattern a, MerchantPattern b) =>
      a.id == b.id &&
      a.category == b.category &&
      a.pattern == b.pattern &&
      a.match == b.match &&
      a.minCents == b.minCents &&
      a.maxCents == b.maxCents &&
      a.order == b.order;

  static MerchantPattern _withOrder(MerchantPattern p, int order) => MerchantPattern(
      id: p.id, category: p.category, pattern: p.pattern, match: p.match, minCents: p.minCents, maxCents: p.maxCents, order: order);

  static (String, String, Map<String, Object?>) _patternWrite(MerchantPattern p) =>
      ('setting', p.id, {'value': jsonEncode(p.toJson()), 'deleted': 0});

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
