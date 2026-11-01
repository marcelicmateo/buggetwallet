/// The synced entities' columns, typed once. Everything that must agree on them is derived from [entitySchema]:
/// the `CREATE TABLE` statements and the column migration ([schemaSql], [ColumnDef.ddl]), the type check of an
/// incoming op's values (`WalletRepo.applyRemote`), the snapshot writer, `WalletRepo.isEmpty` and search
/// (`searchRows`). `test/support/sim.dart` keeps an independent copy as the oracle, and `test/schema_test.dart` pins
/// the generated DDL to the text the first builds ran.
library;

/// How a synced column's values are stored and checked: text, an integer, or a 0/1 flag (a bool is stored as 0/1).
enum ColumnType { text, integer, flag }

/// One column of a synced entity.
class ColumnDef {
  final String name;
  final ColumnType type;

  /// May hold NULL (then it has no default); otherwise it is `NOT NULL` with [defaultSql].
  final bool nullable;

  /// Search looks at it: text by folded substring, an integer by exact amount (see `searchRows`).
  final bool searchable;

  /// The SQL literal after `DEFAULT` for a non-nullable column: `''` for text and `0` for integers unless given.
  final String? defaultSql;

  const ColumnDef(this.name, {this.type = ColumnType.text, this.nullable = false, this.searchable = false, this.defaultSql});
  const ColumnDef.integer(this.name, {this.nullable = false, this.searchable = false, this.defaultSql}) : type = ColumnType.integer;
  const ColumnDef.flag(this.name)
      : type = ColumnType.flag,
        nullable = false,
        searchable = false,
        defaultSql = null;

  /// The column's part of a `CREATE TABLE` or `ADD COLUMN` statement.
  String get ddl {
    final sqlType = type == ColumnType.text ? 'TEXT' : 'INTEGER';
    if (nullable) return '$name $sqlType';
    return "$name $sqlType NOT NULL DEFAULT ${defaultSql ?? (type == ColumnType.text ? "''" : '0')}";
  }
}

/// A synced entity: its table (the entity name in ops can differ, e.g. `goal` → `goals`), its columns after the
/// implicit `id TEXT PRIMARY KEY`, and its indexes (name → column).
class EntityDef {
  final String table;
  final List<ColumnDef> columns;
  final Map<String, String> indexes;
  const EntityDef(this.table, this.columns, {this.indexes = const {}});

  ColumnDef? column(String name) {
    for (final c in columns) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// The syncable column names, in table order.
  List<String> get columnNames => [for (final c in columns) c.name];

  /// `CREATE TABLE IF NOT EXISTS` for the table and its indexes.
  String get createSql => [
        'CREATE TABLE IF NOT EXISTS $table(id TEXT PRIMARY KEY, ${columns.map((c) => c.ddl).join(', ')});',
        for (final e in indexes.entries) 'CREATE INDEX IF NOT EXISTS ${e.key} ON $table(${e.value});',
      ].join('\n');
}

/// Entity name (as in ops) → its definition. Add a new synced entity or field here (and only here); existing devices
/// gain a missing column on open (columns are added, never renamed), and `WalletRepo.schemaVersion` is bumped so the
/// ops older builds skipped are replayed.
const Map<String, EntityDef> entitySchema = {
  'tx': EntityDef('tx', [
    ColumnDef('source'),
    ColumnDef('date'),
    ColumnDef.integer('amount', searchable: true),
    ColumnDef('currency', defaultSql: "'EUR'"),
    ColumnDef('bank_type'),
    ColumnDef('description', searchable: true),
    ColumnDef('category', nullable: true, searchable: true),
    ColumnDef('note', nullable: true, searchable: true),
    ColumnDef.flag('manual'),
    ColumnDef('matched_to', nullable: true),
    ColumnDef.flag('deleted'),
    ColumnDef('seen_bank', nullable: true),
    // v3: the importer's TxKind name, written once by importBatch; the other side of an own transfer.
    ColumnDef('kind_hint', nullable: true),
    ColumnDef('transfer_to', nullable: true),
    // v19 (D2 Unlink): a hand-added entry's bank rows the owner unlinked it from, a JSON list (`matchOffIds`).
    ColumnDef('match_off', nullable: true),
    // v20 (UX-A): the minor digits `amount` is stored in, for a currency without 2 (JPY 0, KWD 3, BTC 8); null = 2,
    // the scale every build before schema 20 used for every currency (`legacyMinor` reads those rows).
    ColumnDef.integer('digits', nullable: true),
  ], indexes: {
    'tx_date': 'date',
    'tx_amount': 'amount'
  }),
  'goal': EntityDef('goals', [
    ColumnDef('name', nullable: true, searchable: true),
    ColumnDef.integer('target', searchable: true),
    ColumnDef.integer('saved', searchable: true),
    ColumnDef.integer('monthly'),
    ColumnDef.integer('sort'),
    ColumnDef.flag('deleted'),
  ]),
  'wish': EntityDef('wish', [
    ColumnDef('name', nullable: true, searchable: true),
    ColumnDef.integer('price', searchable: true),
    ColumnDef.integer('added'),
    ColumnDef('status', defaultSql: "'waiting'"),
    ColumnDef.integer('decided', nullable: true),
    ColumnDef.flag('deleted'),
  ]),
  'setting': EntityDef('settings', [ColumnDef('value', nullable: true), ColumnDef.flag('deleted')]),
  'rule': EntityDef('merchant_rules', [ColumnDef('category', nullable: true), ColumnDef.flag('deleted')]),
  // Amounts added to a goal's saved total, one row each (see `WalletRepo.addGoalContribution`).
  'goal_contrib': EntityDef('goal_contrib', [
    ColumnDef('goal_id'),
    ColumnDef.integer('amount'),
    ColumnDef('date'),
    ColumnDef.flag('deleted'),
  ], indexes: {
    'goal_contrib_goal': 'goal_id'
  }),
  // Recurring bills (v5): detected candidates and the owner's confirm/dismiss decisions (see `RecurringBill`).
  'recurring': EntityDef('recurring', [
    ColumnDef('payee'),
    ColumnDef('label', searchable: true),
    ColumnDef('category', searchable: true),
    ColumnDef.integer('expected_amount', searchable: true),
    ColumnDef.integer('interval_days', defaultSql: '30'),
    ColumnDef('next_due'),
    ColumnDef('status', defaultSql: "'candidate'"),
    ColumnDef('last_paid_tx', nullable: true),
    ColumnDef.flag('deleted'),
    // P4 (v12): amount range (cents), last due date of an instalment plan, added by hand.
    ColumnDef.integer('min_amount', nullable: true),
    ColumnDef.integer('max_amount', nullable: true),
    ColumnDef('ends_on', nullable: true),
    ColumnDef.flag('manual'),
    ColumnDef.flag('own_category'), // the owner chose the category (updateRecurring/addRecurring)
    // P9 (v14): null/'out' = a bill, 'in' = a recurring income.
    ColumnDef('direction', nullable: true),
  ]),
  // Planned costs (v6, §4.3): hand-added, calendar events given an amount or dismissed (see `PlannedCost`).
  'planned': EntityDef('planned', [
    ColumnDef('title', searchable: true),
    ColumnDef('date'),
    ColumnDef.integer('amount', nullable: true, searchable: true),
    ColumnDef('category', nullable: true, searchable: true),
    ColumnDef('source', defaultSql: "'manual'"),
    ColumnDef('source_ref', nullable: true),
    ColumnDef('status', defaultSql: "'open'"),
    ColumnDef('paid_tx', nullable: true),
    ColumnDef.flag('deleted'),
    // v19 (KL-A): the bank rows the owner reopened this cost from after it was paid by them, a JSON list
    // (`PlannedCost.autoOff`): auto-Paid ([planAutoPaid]) never picks one of them again.
    ColumnDef('auto_off', nullable: true),
  ], indexes: {
    'planned_date': 'date'
  }),
  // Bills (v7, stage B): receipts, slips, e-invoices, PDFs and photos (see `Bill`).
  'bill': EntityDef('bills', [
    ColumnDef('source', defaultSql: "'manual'"),
    ColumnDef('status', defaultSql: "'review'"),
    ColumnDef('external_id', nullable: true),
    ColumnDef('date', nullable: true),
    ColumnDef('due_date', nullable: true),
    ColumnDef('payee', nullable: true, searchable: true),
    ColumnDef('iban', nullable: true),
    ColumnDef('reference', nullable: true),
    ColumnDef('description', nullable: true, searchable: true),
    ColumnDef('category', nullable: true),
    ColumnDef('note', nullable: true),
    ColumnDef.integer('total', nullable: true, searchable: true),
    ColumnDef('currency', defaultSql: "'EUR'"),
    ColumnDef('items', defaultSql: "'[]'"),
    ColumnDef.integer('unsure'),
    ColumnDef('linked_tx', nullable: true),
    ColumnDef('warranty_until', nullable: true),
    ColumnDef('return_by', nullable: true),
    ColumnDef('blob', nullable: true),
    ColumnDef('blob_type', nullable: true),
    ColumnDef.integer('blob_bytes', nullable: true),
    ColumnDef.flag('deleted'),
    // v16 (P16b): the payment an attachment belongs to; `linked_tx` stays null for attachments, so builds before
    // P16b never take one for the bill that paid a row. No index: the DDL (with its indexes) runs before the column
    // migration adds this column to an existing table.
    ColumnDef('attached_tx', nullable: true),
    // v20 (UX-A): this bill's own reminder days before its return-by / warranty date; null = the wallet setting.
    ColumnDef.integer('return_reminder_days', nullable: true),
    ColumnDef.integer('warranty_reminder_days', nullable: true),
  ], indexes: {
    'bills_date': 'date',
    'bills_linked': 'linked_tx'
  }),
  // Accounts (v9, N2): the owner's bank and cash accounts with an opening balance (see `Account`).
  'account': EntityDef('accounts', [
    ColumnDef('name', searchable: true),
    ColumnDef('source', nullable: true),
    ColumnDef('currency', defaultSql: "'EUR'"),
    ColumnDef.integer('opening'),
    ColumnDef('opening_date'),
    ColumnDef.flag('deleted'),
    // v20 (UX-A): `AccountKind` wire name (null = from `source`: none → cash, any → bank) and free-text institution.
    ColumnDef('kind', nullable: true),
    ColumnDef('institution', nullable: true, searchable: true),
  ]),
  // Categories (v10, P1): custom categories and subcategories, and overrides of the built-ins (see `CategoryRow`).
  'category': EntityDef('categories', [
    ColumnDef('name', searchable: true),
    ColumnDef('kind'),
    ColumnDef('parent', nullable: true),
    ColumnDef.integer('position', nullable: true),
    ColumnDef.flag('hidden'),
    ColumnDef.flag('deleted'),
  ]),
  // Tags (v11, T1): the owner's extra tags (see `TagRow`), per-row links (`<txId>|<tagId>`, state on/off) and
  // per-payee rule tags (`<payee>|<tagId>`).
  'tag': EntityDef('tags', [
    ColumnDef('name', searchable: true),
    ColumnDef.integer('position', nullable: true),
    ColumnDef.flag('hidden'),
    ColumnDef.flag('deleted'),
  ]),
  'txtag': EntityDef('tx_tags', [
    ColumnDef('tx'),
    ColumnDef('tag'),
    ColumnDef('state'),
  ]),
  'ruletag': EntityDef('rule_tags', [
    ColumnDef('payee'),
    ColumnDef('tag'),
    ColumnDef.flag('deleted'),
  ]),
  // Split transactions (v13, P6): id = the tx id; the whole split is one JSON field (see `SplitPart`), so
  // last-writer-wins never mixes two devices' parts.
  'split': EntityDef('tx_splits', [
    ColumnDef('parts', defaultSql: "'[]'"),
    ColumnDef.flag('deleted'),
  ]),
  // IOUs (v17, Q8): money lent to or borrowed from a person (see `Iou`), and its repayments (`IouPart`). A payment
  // linked through `tx` is neither spending nor income (`Categorizer.iouTx`).
  'iou': EntityDef('ious', [
    ColumnDef('person', searchable: true),
    ColumnDef('direction', defaultSql: "'lent'"),
    ColumnDef.integer('amount'),
    ColumnDef('currency', defaultSql: "'EUR'"),
    ColumnDef('date'),
    ColumnDef('note', nullable: true, searchable: true),
    ColumnDef('tx', nullable: true),
    ColumnDef.flag('closed'),
    ColumnDef.flag('deleted'),
  ]),
  'iou_part': EntityDef('iou_parts', [
    ColumnDef('iou_id'),
    ColumnDef.integer('amount'),
    ColumnDef('date'),
    ColumnDef('tx', nullable: true),
    ColumnDef.flag('deleted'),
  ], indexes: {
    'iou_parts_iou': 'iou_id'
  }),
  // Weekly reviews done (v18, V3): id = the review date (two devices reviewing on one day write the same row), `done`
  // = that date. The streak is read from these rows (`reviewStreak`), so two devices never overwrite each other's count.
  'review': EntityDef('reviews', [
    ColumnDef('done'),
    ColumnDef.flag('deleted'),
  ]),
  // Payee aliases (v19, KL-A): id = `pa:` + 16 hex of the SHA-256 of [alias] (`payeeAliasId`); a slip's payee key
  // ([alias], `billPayeeKey` of the slip) read as the recurring bill payee key [payee] (one step, never a chain).
  'payee_alias': EntityDef('payee_aliases', [
    ColumnDef('alias'),
    ColumnDef('payee'),
    ColumnDef.flag('deleted'),
  ]),
};

/// The device-local tables: never synced or backed up.
const localTablesSql = '''
CREATE TABLE IF NOT EXISTS blob_cache(hash TEXT PRIMARY KEY, sealed BLOB NOT NULL, used_at INTEGER NOT NULL, bytes INTEGER NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS clocks(entity TEXT NOT NULL, id TEXT NOT NULL, field TEXT NOT NULL, hlc TEXT NOT NULL, PRIMARY KEY(entity, id, field));
CREATE TABLE IF NOT EXISTS outbox(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS sync_cursor(device TEXT PRIMARY KEY, seq INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS sync_files(device TEXT NOT NULL, seq INTEGER NOT NULL, ops INTEGER NOT NULL, PRIMARY KEY(device, seq));
''';

/// The whole schema: `meta`, every synced entity's table and indexes ([entitySchema], in order), the local tables.
/// `CREATE TABLE IF NOT EXISTS` throughout, so an older database keeps its tables and only gains the missing ones.
final String schemaSql = [
  'CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);',
  for (final e in entitySchema.values) e.createSql,
  localTablesSql,
].join('\n');
