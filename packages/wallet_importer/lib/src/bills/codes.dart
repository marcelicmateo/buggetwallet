// Readers for scanned codes: the Croatian fiscal receipt QR and the HUB-3 payment slip barcode (PDF417 text).
import 'package:logging/logging.dart';

import '../log.dart';
import 'common.dart';
import 'model.dart';

final _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final _zki = RegExp(r'^[0-9a-fA-F]{32}$');
final _datv = RegExp(r'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})$');
final _izn = RegExp(r'^(\d{1,12})(?:[.,](\d{1,2}))?$');

/// Reads a Croatian fiscal receipt QR: `https://porezna.gov.hr/rn?jir=<uuid>|zki=<32 hex>&datv=YYYYMMDD_HHMM&izn=<amount>`.
/// `izn` is cents as digits (`1250`) or a decimal (`12,50` / `12.50`). Any other host, path or shape → `null`.
NormalizedBill? readFiscalQr(String payload) {
  final bill = _fiscalQr(payload);
  logImporter(billsLog, Level.FINE, 'bills.qr', {'chars': payload.length, 'ok': bill != null});
  return bill;
}

NormalizedBill? _fiscalQr(String payload) {
  final p = payload.trim();
  if (p.isEmpty || p.length > 1000) return null;
  final uri = Uri.tryParse(p);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return null;
  final host = uri.host.toLowerCase();
  if (host != 'porezna.gov.hr' && host != 'www.porezna.gov.hr') return null;
  if (uri.path != '/rn' && uri.path != '/rn/') return null;
  final Map<String, List<String>> q;
  try {
    q = uri.queryParametersAll;
  } catch (_) {
    return null; // bad percent-encoding
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
    if (id == null || datv == null || izn == null) return null;
    final d = _datv.firstMatch(datv);
    if (d == null) return null;
    final date = isoDate(int.parse(d[1]!), int.parse(d[2]!), int.parse(d[3]!));
    if (date == null || int.parse(d[4]!) > 23 || int.parse(d[5]!) > 59) return null;
    final a = _izn.firstMatch(izn);
    if (a == null) return null;
    final total = a[2] == null ? int.parse(a[1]!) : int.parse(a[1]!) * 100 + int.parse(a[2]!.padRight(2, '0'));
    return NormalizedBill(source: BillSource.receiptQr, externalId: id, date: date, total: total);
  } on FormatException {
    return null;
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
/// `hub3:<IBAN>:<model reference>:<amount>` and is only set when the IBAN is valid.
NormalizedBill? readHub3(String payload) {
  final bill = _hub3(payload);
  logImporter(billsLog, Level.FINE, 'bills.hub3', {'chars': payload.length, 'ok': bill != null, if (bill != null) 'unsure': bill.unsure});
  return bill;
}

NormalizedBill? _hub3(String payload) {
  if (payload.length > 2000) return null;
  final lines = payload.split(RegExp(r'\r?\n'));
  // trailing empty lines past the 14th are fine (an empty description is itself an empty 14th line)
  while (lines.length > 14 && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  if (lines.length != 14 || lines[0].trim() != 'HRVHUB30') return null;
  final f = [for (final l in lines) l.trim()];
  final currency = f[1].toUpperCase();
  if (!_currency.hasMatch(currency) || !_amount.hasMatch(f[2])) return null;
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
  return NormalizedBill(
    source: BillSource.hub3,
    externalId: iban == null ? null : 'hub3:$iban:${reference ?? ''}:$amount',
    payee: nonEmpty(f[6]),
    iban: iban,
    reference: reference,
    description: nonEmpty(f[13]),
    total: amount == 0 ? null : amount,
    currency: currency,
    unsure: unsure,
  );
}
