// Helpers shared by the bill readers: IBAN checks, references, exact money and date parsing. Pure Dart, web-safe.
import 'package:logging/logging.dart';

final billsLog = Logger('bw.importer.bills');

/// `true` when [iban] (spaces allowed) is a well-formed IBAN whose mod-97 check holds.
bool validIban(String iban) {
  final s = iban.replaceAll(' ', '').toUpperCase();
  if (!RegExp(r'^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$').hasMatch(s)) return false;
  final r = s.substring(4) + s.substring(0, 4);
  var mod = 0;
  for (final c in r.codeUnits) {
    if (c >= 0x30 && c <= 0x39) {
      mod = (mod * 10 + c - 0x30) % 97;
    } else {
      mod = (mod * 100 + c - 0x41 + 10) % 97;
    }
  }
  return mod == 1;
}

/// A Croatian IBAN (`HR` + 19 digits) with a valid checksum, normalized without spaces; `null` otherwise.
String? hrIban(String text) {
  final s = text.replaceAll(' ', '').toUpperCase();
  if (!RegExp(r'^HR\d{19}$').hasMatch(s)) return null;
  return validIban(s) ? s : null;
}

final _model = RegExp(r'^HR\d{2}$');
final _refBody = RegExp(r'^[0-9][0-9-]{0,21}$');

/// Model + poziv na broj as `HR01 1234-5678`; `null` when the model is not `HRnn` or the reference is not digits and dashes.
/// A model without a reference (e.g. `HR99`) gives just the model.
String? normalizeReference(String model, String reference) {
  final m = model.trim().toUpperCase();
  if (!_model.hasMatch(m)) return null;
  final r = reference.replaceAll(RegExp(r'\s'), '');
  if (r.isEmpty) return m;
  if (!_refBody.hasMatch(r) || r.endsWith('-') || r.contains('--')) return null;
  return '$m $r';
}

/// `YYYY-MM-DD` when the parts are a real calendar date (years 1990–2199), else `null`.
String? isoDate(int y, int m, int d) {
  if (y < 1990 || y > 2199 || m < 1 || m > 12 || d < 1) return null;
  const days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  final leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
  final max = m == 2 && leap ? 29 : days[m - 1];
  if (d > max) return null;
  return '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
}

final _isoDate = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// An ISO date string checked for a real calendar day; `null` otherwise.
String? checkIso(String? s) {
  final m = _isoDate.firstMatch(s?.trim() ?? '');
  if (m == null) return null;
  return isoDate(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
}

/// Cents from a plain decimal (`12`, `12.5`, `12.50`, `-3.10`; [comma] also allows `,` as the decimal point).
/// Exact: no doubles; digits past the cents must be zeros, else `null`.
int? decimalCents(String s, {bool comma = false}) {
  final m = (comma ? RegExp(r'^(-?)(\d{1,13})(?:[.,](\d+))?$') : RegExp(r'^(-?)(\d{1,13})(?:\.(\d+))?$')).firstMatch(s.trim());
  if (m == null) return null;
  var frac = m[3] ?? '';
  if (frac.length > 2) {
    if (frac.length > 20 || frac.substring(2).replaceAll('0', '').isNotEmpty) return null;
    frac = frac.substring(0, 2);
  }
  final cents = int.parse(m[2]!) * 100 + int.parse(frac.padRight(2, '0'));
  return m[1] == '-' ? -cents : cents;
}
