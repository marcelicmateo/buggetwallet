// Money owed to or by people (Q8) in the controller. Core (`repo_iou.dart`) checks every rule and throws an owner-readable
// [ArgumentError]; this caches the lists per data version, adds the row tags and logs. A `part` of controller.dart so it can use the cache
// and `_changed`.
//
// Privacy: logs carry counts and enum words only, never people, notes or amounts.
part of 'controller.dart';

final _iouLog = Logger('bw.iou');

/// "People owe you X · You owe Y" per currency (never added together): [owedToYou] and [youOwe] by currency code.
class OwedTotals {
  final Map<String, int> owedToYou, youOwe;

  /// Every currency with an open IOU, the wallet's own first, then the others by code.
  final List<String> currencies;
  const OwedTotals(this.owedToYou, this.youOwe, this.currencies);
}

extension IouDb on WalletController {
  /// The live IOUs, newest first, closed ones included. Cached.
  List<IouView> iousAll() => _cached(const MemoKey('iousAll'), () => repo.ious());

  /// The open IOUs (not closed, still owing something or not paid back in full).
  List<IouView> iousOpen() => [
        for (final v in iousAll())
          if (!v.iou.closed) v
      ];

  /// What people owe you and what you owe, over the open IOUs, per currency.
  OwedTotals owedTotals() => _cached(const MemoKey('owedTotals'), () {
        final to = <String, int>{}, by = <String, int>{};
        for (final v in iousOpen()) {
          final m = v.iou.direction == IouDirection.lent ? to : by;
          m[v.iou.currency] = (m[v.iou.currency] ?? 0) + v.outstanding;
        }
        final all = {...to.keys, ...by.keys}.toList()..sort();
        return OwedTotals(to, by, [if (all.remove(currency)) currency, ...all]);
      });

  /// The IOU [id], or null when it is gone.
  IouView? iouById(String id) {
    for (final v in iousAll()) {
      if (v.iou.id == id) return v;
    }
    return null;
  }

  /// The tag a payment row shows when it is linked to an IOU: `lent` / `borrowed` (the loan itself) or `repaid` (a repayment), by payment id.
  /// A hand-added entry replaced by a bank row passes its tag to that row.
  Map<String, String> iouTags() => _cached(const MemoKey('iouTags'), () {
        final out = <String, String>{};
        void put(String? id, String tag) {
          if (id == null || id.isEmpty) return;
          out[id] = tag;
          final m = wholeTxs.where((t) => t.tx.id == id).firstOrNull?.tx.matchedTo;
          if (m != null) out[m] = tag;
        }

        for (final v in iousAll()) {
          put(v.iou.tx, v.iou.direction == IouDirection.lent ? 'lent' : 'borrowed');
          for (final p in v.parts) {
            put(p.tx, 'repaid');
          }
        }
        return out;
      });

  /// The tag of payment [txId] ("lent", "borrowed", "repaid") or null.
  String? iouTagOf(String txId) => iouTags()[txId];

  /// The open IOUs a payment of [amount] cents (positive, in [currency]) could repay: lent ones for money in, as long as they still
  /// owe at least that much. Core refuses the rest.
  List<IouView> repayableBy(int amount, String currency) => [
        for (final v in iousOpen())
          if (v.iou.direction == IouDirection.lent && v.iou.currency == currency && v.outstanding >= amount) v
      ];

  /// Adds an IOU and returns its id; [tx] links the payment that was the loan. An [ArgumentError] carries core's readable text.
  String addIou(
      {required String person,
      required IouDirection direction,
      required int amount,
      required String date,
      String? note,
      String? tx,
      String? currency}) {
    final id = repo.addIou(
        person: person, direction: direction, amount: amount, currency: currency ?? this.currency, date: date, note: note, tx: tx);
    _changed();
    return id;
  }

  void closeIou(String id, {bool closed = true}) {
    repo.closeIou(id, closed: closed);
    _changed();
  }

  void deleteIou(String id) {
    repo.deleteIou(id);
    _changed();
  }

  /// Undo of [deleteIou].
  void undeleteIou(String id) {
    repo.undeleteIou(id);
    _changed();
  }

  /// A repayment of [amount] on [date]; [tx] is the payment that repaid it (money in for a lent IOU).
  String addIouPart(String iouId, {required int amount, required String date, String? tx}) {
    final id = repo.addIouPart(iouId, amount: amount, date: date, tx: tx);
    _changed();
    return id;
  }

  void deleteIouPart(String id) {
    repo.deleteIouPart(id);
    _changed();
  }

  /// Undo of [deleteIouPart].
  void undeleteIouPart(String id) {
    repo.undeleteIouPart(id);
    _changed();
  }

  /// Logs that an IOU sheet was opened (counts only).
  void logIouOpen(int parts) => logEvent(_iouLog, Level.FINE, 'iou.open', {'parts': parts});
}
