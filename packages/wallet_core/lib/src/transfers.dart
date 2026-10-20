import 'package:wallet_importer/wallet_importer.dart' show TxKind;

import 'dates.dart';
import 'logs.dart';
import 'models.dart';

final _log = Logger('bw.transfers');
final _iso = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Days the two sides of a transfer between the owner's own accounts may be booked apart (inclusive, either way in
/// time): an outflow on the 10th pairs with an inflow from the 7th to the 13th.
const transferDays = 3;

/// What [planTransfers] wants written: `transfer_to` per row id (the partner's id, or null to reopen a row whose
/// partner is gone).
class TransferPlan {
  final Map<String, String?> transferTo;

  /// New pairs (two rows each).
  final int paired;
  const TransferPlan(this.transferTo, this.paired);
  bool get isEmpty => transferTo.isEmpty;

  /// Rows whose stale link is cleared without a new partner.
  int get reopened => transferTo.values.where((v) => v == null).length;
}

/// Whether [t] carries the bank's own evidence of a transfer between the owner's accounts (the importer's
/// `kindHint`). Only such a row may pair: money is never reclassified on amount alone.
bool _own(Tx t) => t.kindHint == TxKind.ownTransfer;

/// Whether [t]'s `transfer_to` link holds: the partner is live, a bank row, points back, and one of the two is a
/// hinted own transfer ([_own]). A pair with no hint on either side was made by the amount-only rule of an earlier
/// build and dissolves. A partner that is not in [byId] at all (its sync file has not arrived yet) keeps the link:
/// the devices holding it decide, and reopening the row here would only start a rewrite war over sync.
bool _linked(Tx t, Map<String, Tx> byId) {
  final to = t.transferTo;
  if (to == null || to == t.id) return false;
  final p = byId[to];
  if (p == null) return true;
  return !p.deleted && !p.manual && p.transferTo == t.id && (_own(t) || _own(p));
}

/// The rows of [rows] that need a partner: live bank rows (not manual, not deleted, with a date) that have no
/// `transfer_to`, or whose link no longer holds ([_linked]).
List<Tx> openTransfers(List<Tx> rows) {
  final byId = {for (final t in rows) t.id: t};
  return [
    for (final t in rows)
      if (!t.manual && !t.deleted && t.amount != 0 && _iso.hasMatch(t.date) && !_linked(t, byId)) t
  ];
}

/// Pairs the two sides of a transfer between the owner's own accounts: a row the bank itself marks as one
/// (`kindHint == ownTransfer`: a Revolut top-up, a PBZ card payment to Revolut) and the same amount, in the same
/// currency, with the opposite sign, in another source within [transferDays]. Both rows then carry the other's id in
/// `transfer_to`, and the categorizer shows them as `Internal transfer`.
///
/// Money is never reclassified on amount alone (owner rule): two rows without a hint never pair, whatever their
/// amounts and dates (a 50 € card payment and an unrelated 50 € received elsewhere two days later both stay spending).
/// A hinted row with no partner is an `Internal transfer` by its hint alone; an unhinted row is hidden only as the
/// partner of a hinted one.
///
/// A pure function of the rows, so every device holding the same rows plans the same pairs (sync converges in
/// whichever order the two banks' rows arrive), and applying the plan gives a state whose plan is empty:
/// - a holding pair is kept as it is (never re-planned), also while the partner has not arrived on this device;
/// - a row whose partner is deleted, is not a bank row, or points at another row is open again; so are both rows of
///   a pair with no hint on either side (made by an earlier build's amount-only rule): they get `transfer_to` cleared
///   and return to their normal categories, on every device that holds both;
/// - open outflows are taken oldest first (date, then id); each takes the free open inflow from another source with
///   the opposite amount and the same currency, one of the two hinted, that is closest in days, then earliest in
///   date, then smallest in id. A row pairs at most once;
/// - an open row whose stale link found no new partner gets `transfer_to` cleared.
///
/// [rows]: the candidate rows plus every row one of them points at (deleted or not), so links can be checked. A
/// target missing from [rows] counts as not arrived yet.
TransferPlan planTransfers(List<Tx> rows) {
  final open = openTransfers(rows)
    ..sort((a, b) {
      final d = a.date.compareTo(b.date);
      return d != 0 ? d : a.id.compareTo(b.id);
    });
  final inflows = <(int, String), List<Tx>>{};
  for (final t in open) {
    if (t.amount > 0) (inflows[(t.amount, t.currency)] ??= []).add(t);
  }
  final out = <String, String?>{};
  final taken = <String>{};
  var paired = 0;
  for (final o in open) {
    if (o.amount >= 0) continue;
    final pool = inflows[(-o.amount, o.currency)];
    if (pool == null) continue;
    Tx? best;
    var bestDays = 0;
    for (final i in pool) {
      if (i.source == o.source || taken.contains(i.id) || !(_own(o) || _own(i))) continue;
      final days = daysBetween(o.date, i.date).abs();
      if (days > transferDays) continue;
      if (best == null ||
          days < bestDays ||
          (days == bestDays && (i.date.compareTo(best.date) < 0 || (i.date == best.date && i.id.compareTo(best.id) < 0)))) {
        best = i;
        bestDays = days;
      }
    }
    if (best == null) continue;
    taken.add(o.id);
    taken.add(best.id);
    out[o.id] = best.id;
    out[best.id] = o.id;
    paired++;
  }
  for (final t in open) {
    if (t.transferTo != null && !out.containsKey(t.id)) out[t.id] = null;
  }
  final plan = TransferPlan(out, paired);
  logEvent(_log, Level.FINE, 'transfers.plan', {'rows': rows.length, 'open': open.length, 'paired': paired, 'reopened': plan.reopened});
  return plan;
}
