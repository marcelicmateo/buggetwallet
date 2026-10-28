// VC (Stage V): a field two devices hold with the same clock but different values, found by a repair resend. Kept
// device-locally until the owner chooses (WalletRepo.resolveSyncConflict) or an edit of the field settles it. Web-safe.

/// One field this device and another hold with the same clock ([clock]) but different values. Device-local, never
/// synced. [mine] is this device's current value, [theirs] the other device's (the latest one seen). Values are as
/// stored: integers (cents, 0/1 flags, dates in ms), text or null.
class SyncConflict {
  /// Stable id of the field: `<entity>|<rowId>|<field>`.
  final String id;
  final String entity, rowId, field;
  final Object? mine, theirs;

  /// The field clock both devices hold (HLC text).
  final String clock;
  const SyncConflict(
      {required this.id,
      required this.entity,
      required this.rowId,
      required this.field,
      required this.mine,
      required this.theirs,
      required this.clock});

  static String idOf(String entity, String rowId, String field) => '$entity|$rowId|$field';

  Map<String, Object?> toJson() => {'e': entity, 'r': rowId, 'f': field, 't': theirs, 'c': clock};

  /// A stored entry ([toJson]) with [mine] read now; null when it does not parse.
  static SyncConflict? fromJson(Object? j, {Object? mine}) {
    if (j is! Map) return null;
    final (e, r, f, c) = (j['e'], j['r'], j['f'], j['c']);
    if (e is! String || r is! String || f is! String || c is! String) return null;
    return SyncConflict(id: idOf(e, r, f), entity: e, rowId: r, field: f, mine: mine, theirs: j['t'], clock: c);
  }

  @override
  String toString() => 'SyncConflict($entity)';
}
