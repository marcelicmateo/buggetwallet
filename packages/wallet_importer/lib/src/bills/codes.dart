// Readers for scanned codes: the Croatian fiscal receipt QR and the HUB-3 payment slip barcode (PDF417 text).
import 'package:logging/logging.dart';

import '../log.dart';
import 'common.dart';
import 'model.dart';
import 'read_result.dart';

final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _zki = RegExp(r'^[0-9a-fA-F]{32}$');
final _datv = RegExp(r'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})$');
final _izn = RegExp(r'^(\d{1,12})(?:[.,](\d{1,2}))?$');

/// Reads a Croatian fiscal receipt QR: `https://porezna.gov.hr/rn?jir=<uuid>|zki=<32 hex>&datv=YYYYMMDD_HHMM&izn=<amount>`.
/// `izn` is cents as digits (`1250`) or a decimal (`12,50` / `12.50`). Any other host, path or shape → `null`.
NormalizedBill? readFiscalQr(String payload) => readFiscalQrResult(payload).value;

/// [readFiscalQr] with the reason when there is no bill.
ReadResult<NormalizedBill> readFiscalQrResult(String payload) {
  final r = _fiscalQr(payload);
  logImporter(billsLog, Level.FINE, 'bills.qr', {'chars': payload.length, 'ok': r.ok});
  return r;
}

ReadResult<NormalizedBill> _fiscalQr(String payload) {
  final p = payload.trim();
  if (p.isEmpty) return const ReadResult.failed(ReadFailure.empty);
  if (p.length > 1000) return const ReadResult.failed(ReadFailure.tooBig);
  final uri = Uri.tryParse(p);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return const ReadResult.failed(ReadFailure.notRecognized);
  final host = uri.host.toLowerCase();
  if (host != 'porezna.gov.hr' && host != 'www.porezna.gov.hr') return const ReadResult.failed(ReadFailure.notRecognized);
  if (uri.path != '/rn' && uri.path != '/rn/') return const ReadResult.failed(ReadFailure.notRecognized);
  final Map<String, List<String>> q;
  try {
    q = uri.queryParametersAll;
  } catch (_) {
    return const ReadResult.failed(ReadFailure.malformed); // bad percent-encoding
  }
  String? one(String key) {
    final v = q[key];
    if (v == null || v.isEmpty) return null;
    if (v.toSet().length > 1) throw const FormatException('conflict');
    return v.first.trim();
  }

  try {
    final jir = one('jir'), zki = one('zki'), datv = one('datv'), izn = one('izn');
    String? id;
    if (jir != null && _uuid.hasMatch(jir)) {
      id = 'jir:${jir.toLowerCase()}';
    } else if (jir == null && zki != null && _zki.hasMatch(zki)) {
      id = 'zki:${zki.toLowerCase()}';
    }
    if (id == null || datv == null || izn == null) return const ReadResult.failed(ReadFailure.malformed);
    final d = _datv.firstMatch(datv);
    if (d == null) return const ReadResult.failed(ReadFailure.malformed);
    final date = isoDate(int.parse(d[1]!), int.parse(d[2]!), int.parse(d[3]!));
    if (date == null || int.parse(d[4]!) > 23 || int.parse(d[5]!) > 59) return const ReadResult.failed(ReadFailure.malformed);
    final a = _izn.firstMatch(izn);
    if (a == null) return const ReadResult.failed(ReadFailure.malformed);
    final total = a[2] == null ? int.parse(a[1]!) : int.parse(a[1]!) * 100 + int.parse(a[2]!.padRight(2, '0'));
    return ReadResult.ok(NormalizedBill(source: BillSource.receiptQr, externalId: id, date: date, total: total));
  } on FormatException {
    return const ReadResult.failed(ReadFailure.malformed);
  }
}

final _currency = RegExp(r'^[A-Z]{3}$');
final _amount = RegExp(r'^\d{1,15}$');

/// Reads the text of a HUB-3 payment slip barcode (PDF417): `HRVHUB30` and 13 more lines (LF or CRLF, trailing empty
/// lines allowed): currency, amount (15 digits, cents), payer name/street/city (skipped: the owner's own data), payee
/// name/street/city, IBAN, model, reference, purpose code, description. Wrong header or line count → `null`.
///
/// An IBAN that fails the HR checksum is dropped (`iban` null, `unsure` + 1); so is a model that is not `HRnn`.
/// An amount of zero (a slip left for the payer to fill in) gives `total` null. `externalId` is
/// `hub3:<IBAN>:<model reference>:<amount>:<description>` (description with runs of spaces made one, upper case; empty
/// when the slip has none) and is only set when the IBAN is valid. The description is in it because a flat fee paid
/// every month (same IBAN, model `HR99` without a reference, same amount) differs only there (BILLS_API.md §1).
NormalizedBill? readHub3(String payload) => readHub3Result(payload).value;

/// [readHub3] with the reason when there is no bill.
ReadResult<NormalizedBill> readHub3Result(String payload) {
  final r = _hub3(payload);
  final bill = r.value;
  logImporter(billsLog, Level.FINE, 'bills.hub3', {'chars': payload.length, 'ok': bill != null, if (bill != null) 'unsure': bill.unsure});
  return r;
}

ReadResult<NormalizedBill> _hub3(String payload) {
  if (payload.length > 2000) return const ReadResult.failed(ReadFailure.tooBig);
  final lines = payload.split(RegExp(r'\r?\n'));
  // trailing empty lines past the 14th are fine (an empty description is itself an empty 14th line)
  while (lines.length > 14 && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  if (lines.length != 14 || lines[0].trim() != 'HRVHUB30') return const ReadResult.failed(ReadFailure.notRecognized);
  final f = [for (final l in lines) l.trim()];
  final currency = f[1].toUpperCase();
  if (!_currency.hasMatch(currency) || !_amount.hasMatch(f[2])) return const ReadResult.failed(ReadFailure.malformed);
  final amount = int.parse(f[2]);
  var unsure = 0;
  String? iban;
  if (f[9].isNotEmpty) {
    iban = hrIban(f[9]);
    if (iban == null) unsure++;
  }
  String? reference;
  if (f[10].isNotEmpty || f[11].isNotEmpty) {
    reference = normalizeReference(f[10], f[11]);
    if (reference == null) unsure++;
  }
  String? nonEmpty(String s) => s.isEmpty ? null : s;
  return ReadResult.ok(NormalizedBill(
    source: BillSource.hub3,
    externalId: iban == null ? null : 'hub3:$iban:${reference ?? ''}:$amount:${f[13].replaceAll(RegExp(r'\s+'), ' ').toUpperCase()}',
    payee: nonEmpty(f[6]),
    iban: iban,
    reference: reference,
    description: nonEmpty(f[13]),
    total: amount == 0 ? null : amount,
    currency: currency,
    unsure: unsure,
  ));
}
