// The ECB exchange rates in the controller (UX-FX, docs/context/UX_SPEC.md). A `part` of controller.dart so it can use `_changed`.
//
// Order (core): `ecbFetchPlan` -> `noteEcbAttempt` -> `deps.ecbFetcher` (wallet_sync's `fetchEcbFile`) -> `importEcbHistory`. Core limits
// the automatic fetch to once a day and only when a rate is missing; this file adds "never on a metered network" and the plain failure
// line for Settings › Accounts › Currencies. A failure never blocks anything and is never a toast.
//
// Privacy: logs carry the trigger, the file (`history`/`recent`), the outcome and counts. Never the address, an error text or a rate.
part of 'controller.dart';

final _ecbLog = Logger('bw.fx');

/// Device-local note of the last failed download: `<reason>|<day>`; removed by the next good one.
const _ecbFailureKey = 'ecbFailure';

/// The last download that failed: why ([reason] is a word of [EcbFetchFailure], `damaged` or `other`) and the day it happened.
class EcbFailure {
  final String reason;
  final String date;
  const EcbFailure(this.reason, this.date);

  /// "no connection", "it took too long": what follows "Couldn't get rates: " on the panel.
  String get why => switch (reason) {
        'unreachable' => 'no connection',
        'timeout' => 'it took too long',
        'status' => 'the ECB did not answer',
        'tooLarge' => 'the download was too large',
        'damaged' => 'the file was damaged',
        _ => 'something went wrong',
      };
}

extension EcbDb on WalletController {
  /// What the device-local ECB cache holds (days, newest day, last good download).
  EcbCacheInfo ecbCacheInfo() => repo.ecbCacheInfo();

  /// How many (currency, date) amounts the wallet counts by an ECB rate that has no rate yet (shown as "not counted").
  int fxMissingCount() => repo.fxMissing().length;

  /// The last failed download, or null (none, or a good one came after it).
  EcbFailure? ecbLastFailure() {
    final v = repo.localValue(_ecbFailureKey);
    if (v == null) return null;
    final i = v.indexOf('|');
    return i < 0 ? null : EcbFailure(v.substring(0, i), v.substring(i + 1));
  }

  /// Whether a wallet currency switch from [old] to [code] leaves the payments in [old] counted by ECB rates of their own days: the
  /// device holds ECB rates and neither is a coin (coins are hand-set only). The ECB publishes about 30 currencies: one it does not
  /// publish stays "not counted" until the owner sets a rate (the Currencies panel says so per currency).
  bool ecbCoversSwitch(String old, String code) =>
      ecbCacheInfo().days > 0 && !(currencyInfo(old)?.crypto ?? false) && !(currencyInfo(code)?.crypto ?? false);

  /// The source of the rate that counts [t] in the wallet currency: "ECB 31 Oct" (the ECB day used), "your rate", or null (no rate
  /// needed or none found). Core's `fxUsed`.
  String? fxSourceOf(Tx t) => fxSourceText(fxUsed(t, settings));

  /// The text for core's [FxUsed].
  String? fxSourceText(FxUsed? u) => u == null ? null : (u.ecb ? 'ECB ${shortDateOrRaw(u.date)}' : 'your rate');

  /// Downloads the rates when the wallet needs some: the automatic run at start and after an import or a sync. Does nothing when core
  /// says there is nothing to fetch (no missing rate, or an attempt was made today) and never on a metered network (no attempt is
  /// noted then, so the next start or sync tries again on another network). A failure is noted for the Currencies panel, nothing more.
  Future<void> fetchRatesAuto({String trigger = 'auto'}) async {
    if (_disposed || ecbFetching) return;
    ecbFetching = true;
    var fetched = false;
    try {
      final EcbFile? plan;
      try {
        plan = repo.ecbFetchPlan();
      } catch (e, st) {
        logError(_ecbLog, 'fx.plan.failed', e, st, fields: {'trigger': trigger});
        return;
      }
      if (plan == null) return;
      var metered = false;
      try {
        metered = await deps.isMetered();
      } catch (e, st) {
        logError(_ecbLog, 'fx.metered.failed', e, st); // treated as unmetered
      }
      if (_disposed) return;
      if (metered) {
        logEvent(_ecbLog, Level.INFO, 'fx.fetchSkipped', {'trigger': trigger, 'reason': 'metered', 'file': plan.name});
        return;
      }
      fetched = true;
      notifyListeners(); // "Getting rates..." on the panel
      await _fetchRates(plan, trigger);
    } finally {
      ecbFetching = false;
      if (fetched && !_disposed) notifyListeners();
    }
  }

  /// "Get rates now": the owner asked, so a metered network and the daily limit do not stop it. True when the rates came in.
  Future<bool> getRatesNow() async {
    if (_disposed || ecbFetching) return false;
    ecbFetching = true;
    notifyListeners();
    try {
      final plan = repo.ecbFetchPlan(force: true);
      if (plan == null) return false;
      return await _fetchRates(plan, 'button');
    } finally {
      ecbFetching = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> _fetchRates(EcbFile file, String trigger) async {
    repo.noteEcbAttempt();
    final f = <String, Object?>{'trigger': trigger, 'file': file.name};
    String? failed;
    try {
      final bytes = await deps.ecbFetcher(file);
      if (_disposed) return false;
      final imp = repo.importEcbHistory(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
      repo.setLocalValue(_ecbFailureKey, null);
      logEvent(_ecbLog, Level.INFO, 'fx.fetch', {...f, 'outcome': 'ok', 'days': imp.days, 'written': imp.written});
      _changed(); // the rates it wrote count in every total now
      return true;
    } on EcbFetchException catch (e) {
      failed = e.reason.name;
    } on FormatException {
      failed = 'damaged'; // core wrote nothing
    } catch (e, st) {
      logError(_ecbLog, 'fx.fetch.failed', e, st, fields: f);
      failed = 'other';
    }
    if (_disposed) return false;
    repo.setLocalValue(_ecbFailureKey, '$failed|${today()}');
    logEvent(_ecbLog, Level.INFO, 'fx.fetch', {...f, 'outcome': 'failed', 'reason': failed});
    return false;
  }
}
