// Stage H12 compatibility shims: the tests are written from the Stage H API contract, but must compile and run on a
// tree where that API does not exist yet. Every shim probes for the new name at run time and returns null / false when
// it is absent, so a test can `skip:` itself with a `BUG: H<n>` reason until the behaviour lands (the skip lifts by
// itself once the probe finds the API). Dynamic calls are the point of this file, hence the ignore.
// ignore_for_file: avoid_dynamic_calls
import 'dart:typed_data';

import 'package:wallet_core/wallet_core.dart';

/// The skip reason for a missing feature: null (run) when [present], else the `BUG:` text.
String? bugUnless(bool present, String item, String what) => present ? null : 'BUG: $item - $what';

final _probeKey = VaultKey(List<int>.filled(32, 7));

bool _accepts(Function f, List<Object?> pos, Map<Symbol, Object?> named) {
  try {
    final r = Function.apply(f, pos, named);
    if (r is Future) r.then<void>((_) {}, onError: (Object _) {});
    return true;
  } on NoSuchMethodError {
    return false;
  } on Object {
    return true; // it was called with those names; it failed for another reason
  }
}

/// `seal(..., aad:)` exists (BWOP2, H8).
final bool sealHasAad = _accepts(seal, [
  const <int>[],
  _probeKey
], {
  #aad: const <int>[1]
});

/// `seal(..., nonce:)` exists (the test seam of H8).
final bool sealHasNonce = _accepts(seal, [
  const <int>[],
  _probeKey
], {
  #aad: const <int>[1],
  #nonce: List<int>.filled(24, 1)
});

/// `RelayState.instance` exists (H5).
final bool hasRelayInstance = () {
  try {
    final v = (RelayState.empty as dynamic).instance;
    return v == null || v is String;
  } on NoSuchMethodError {
    return false;
  }
}();

/// `WalletRepo.open(..., deviceId:)` exists (H6).
final bool openHasDeviceId = _accepts(WalletRepo.inMemory, [], {#deviceId: '0123456789abcdef'});

/// The AAD used by tests that do not care about its value.
const testAad = <int>[0x74, 0x65, 0x73, 0x74];

Future<Uint8List> sealC(List<int> plain, VaultKey key, {List<int> aad = testAad, List<int>? nonce}) async {
  final named = <Symbol, Object?>{if (sealHasAad) #aad: aad, if (nonce != null) #nonce: nonce};
  return Function.apply(seal, [plain, key], named) as Future<Uint8List>;
}

Future<Uint8List> unsealC(List<int> data, VaultKey key, {List<int> aad = testAad}) async {
  final named = <Symbol, Object?>{if (sealHasAad) #aad: aad};
  return Function.apply(unseal, [data, key], named) as Future<Uint8List>;
}

/// An in-memory repo with a chosen device id when the build supports it (else the random one).
WalletRepo repoWithDeviceId(String? deviceId, {int Function()? now}) {
  final named = <Symbol, Object?>{if (now != null) #now: now, if (deviceId != null && openHasDeviceId) #deviceId: deviceId};
  return Function.apply(WalletRepo.inMemory, [], named) as WalletRepo;
}

/// A file-backed repo with a chosen device id when supported.
WalletRepo openRepo(String path, {String? deviceId, int Function()? now, List<int>? dbKey}) {
  final named = <Symbol, Object?>{
    if (now != null) #now: now,
    if (dbKey != null) #dbKey: dbKey,
    if (deviceId != null && openHasDeviceId) #deviceId: deviceId,
  };
  return Function.apply(WalletRepo.open, [path], named) as WalletRepo;
}

T? _try<T>(T Function() f) {
  try {
    return f();
  } on NoSuchMethodError {
    return null;
  }
}

SyncProblemReason? reasonNamed(String name) {
  for (final r in SyncProblemReason.values) {
    if (r.name == name) return r;
  }
  return null;
}

Verdict? verdictNamed(String name) {
  for (final v in Verdict.values) {
    if (v.name == name) return v;
  }
  return null;
}

// Period fields of H1/H2 (null = this build does not have them).
bool? paydayPassedOf(PeriodBudget p) => _try(() => (p as dynamic).paydayPassed as bool);
int? overByOf(PeriodBudget p) => _try(() => (p as dynamic).overBy as int);
int? overTodayOf(PeriodBudget p) => _try(() => (p as dynamic).overToday as int);
bool? lowIncomeOf(PeriodBudget p) => _try(() => (p as dynamic).lowIncome as bool);
Map<String, int>? foreignOf(PeriodBudget p) => _try(() => Map<String, int>.from((p as dynamic).foreignByCurrency as Map));
Map<String, int>? foreignOfMonth(MonthSummary m) => _try(() => Map<String, int>.from((m as dynamic).foreignByCurrency as Map));

/// `averageByCategory` with the required `currency:` of H1; null when not supported.
Map<String, int>? averageByCategoryIn(List<CategorizedTx> txs, String month, String currency) {
  try {
    return Function.apply(averageByCategory, [txs, month], {#currency: currency}) as Map<String, int>;
  } on NoSuchMethodError {
    return null;
  }
}

/// `monthSummary` with an optional `currency:` (H1: the settings carry it, or a named parameter).
MonthSummary? monthSummaryIn(List<CategorizedTx> txs, String month, String currency) {
  try {
    return Function.apply(monthSummary, [txs, month], {#currency: currency}) as MonthSummary;
  } on NoSuchMethodError {
    return null;
  }
}

/// `monthlySummaryCsv(txs, currency:)` of H1; null when not supported.
String? monthlySummaryCsvIn(List<CategorizedTx> txs, String currency) {
  try {
    return Function.apply(monthlySummaryCsv, [txs], {#currency: currency}) as String;
  } on NoSuchMethodError {
    return null;
  }
}

/// `budgetVsActual(..., currency:)` of H1; null when not supported.
BudgetVsActual? budgetVsActualIn(List<CategorizedTx> txs, String month, Map<String, int> budgets, String today, String currency) {
  try {
    return Function.apply(budgetVsActual, [txs, month, budgets], {#today: today, #currency: currency}) as BudgetVsActual;
  } on NoSuchMethodError {
    return null;
  }
}
