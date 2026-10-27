/// Recent changes (Q9): one entry per changed row, read from the device-local `clocks` table by
/// `WalletRepoChanges.recentChanges`. Read-only; web-safe.
library;

/// The last change to one synced row: its [entity] (as in ops: `tx`, `goal`, `setting`, …) and [id], the [fields]
/// written with its newest clock (sorted), that clock's wall time [millis] (ms since the epoch, UTC) and [node] (the
/// writing device's id), whether that device is this one ([thisDevice]), a display [label] (shown on this device only,
/// never logged) and whether the row is now deleted ([deleted]).
class ChangeEntry {
  final String entity;
  final String id;
  final List<String> fields;
  final int millis;
  final String node;
  final bool thisDevice;
  final String label;
  final bool deleted;
  const ChangeEntry(this.entity, this.id, this.fields, this.millis, this.node, this.thisDevice, this.label, this.deleted);

  /// Entity, field count and flags only: never the label, id or node.
  @override
  String toString() => 'ChangeEntry($entity, ${fields.length} fields${thisDevice ? ', here' : ''}${deleted ? ', deleted' : ''})';
}
