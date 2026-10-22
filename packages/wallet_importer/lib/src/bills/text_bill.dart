// Bill fields from free text (a PDF's text layer or OCR): labelled values only, every one counted as unsure.
import 'dart:math' as math;

import 'package:logging/logging.dart';

import '../log.dart';
import 'codes.dart';
import 'common.dart';
import 'model.dart';

/// Characters of text read; the rest is ignored.
const maxBillTextChars = 2000000;
const _maxLine = 2000;

/// Finds a bill in Croatian or English text: HR IBAN (checksum), `HRnn` model + reference, the labelled payable total,
/// due and issue dates, JIR/ZKI after their labels (→ `externalId`) and a payee only after a seller label (Primatelj,
/// Prodavatelj, Izdavatelj, Seller…; never Platitelj/Kupac/Buyer). A HUB-3 block printed as text (`HRVHUB30` + 13
/// lines) is read like [readHub3], and the text fills only what it lacks.
///
/// Money is exact and conservative: a total needs a label, a line with two different amounts after the label is
/// ambiguous, and two labelled totals that differ give `total` null. Every field found in the text adds 1 to
/// `unsure`. Nothing found → `null`. Never throws.
NormalizedBill? billFromText(String text, {required BillSource source}) {
  final fields = <String, Object?>{'source': source.name, 'chars': text.length};
  NormalizedBill? bill;
  try {
    bill = _fromText(text, source, fields);
  } catch (_) {
    fields['reason'] = 'error';
  }
  fields['ok'] = bill != null;
  if (bill != null) fields['unsure'] = bill.unsure;
  logImporter(billsLog, Level.FINE, 'bills.text', fields);
  return bill;
}

final _spaces = RegExp('[    \t]');

NormalizedBill? _fromText(String text, BillSource source, Map<String, Object?> log) {
  var t = text.length > maxBillTextChars ? text.substring(0, maxBillTextChars) : text;
  t = t.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceAll(_spaces, ' ');
  final lines = [for (final l in t.split('\n')) l.length > _maxLine ? l.substring(0, _maxLine) : l];

  NormalizedBill? hub;
  for (var i = 0; i < lines.length && hub == null; i++) {
    if (lines[i].trim() == 'HRVHUB30') hub = readHub3(lines.sublist(i, math.min(i + 14, lines.length)).join('\n'));
  }

  final iban = _iban(lines);
  final reference = _reference(lines);
  final (total, currency) = _total(lines);
  final dueDate = _labelledDate(lines, [_dueLabel]);
  final date = _labelledDate(lines, [_issueLabel, _plainDateLabel], skip: _dueLabel);
  final externalId = _fiscalId(t);
  final payee = _payee(lines);
  log['hub3'] = hub != null;

  var unsure = hub?.unsure ?? 0;
  T? pick<T>(T? fromHub, T? fromText) {
    if (fromHub != null) return fromHub;
    if (fromText != null) unsure++;
    return fromText;
  }

  final bill = NormalizedBill(
    source: source,
    externalId: pick(hub?.externalId, externalId),
    date: pick(null, date),
    dueDate: pick(null, dueDate),
    payee: pick(hub?.payee, payee),
    iban: pick(hub?.iban, iban),
    reference: pick(hub?.reference, reference),
    description: hub?.description,
    total: pick(hub?.total, total),
    currency: hub?.currency ?? (total != null ? currency : 'EUR'),
    unsure: unsure,
  );
  final found = [bill.externalId, bill.date, bill.dueDate, bill.payee, bill.iban, bill.reference, bill.description, bill.total]
      .where((v) => v != null)
      .length;
  log['found'] = found;
  return found == 0 ? null : bill;
}

RegExp _re(String p) => RegExp(p, caseSensitive: false, unicode: true);

// ---------- IBAN ----------
final _ibanRe = _re(r'(?<![\p{L}\d])HR\d{2}(?: ?\d){17}(?!\d)');
final _payerLabel = _re(r'(?<!\p{L})(platitelj\p{L}*|kupac|kupca|buyer|customer|bill\s+to)(?!\p{L})');
final _payeeContext = _re(r'(?<!\p{L})(iban|primatelj\p{L}*|prodavatelj|izdavatelj|seller|payee|supplier|žiro|uplat\p{L}*)(?!\p{L})');

String? _iban(List<String> lines) {
  final all = <String>{}, labelled = <String>{};
  for (final line in lines) {
    final payer = _payerLabel.hasMatch(line) && !_payeeContext.hasMatch(line);
    for (final m in _ibanRe.allMatches(line)) {
      final iban = hrIban(m[0]!);
      if (iban == null || payer) continue;
      all.add(iban);
      if (_payeeContext.hasMatch(line)) labelled.add(iban);
    }
  }
  if (all.length == 1) return all.first;
  return labelled.length == 1 ? labelled.first : null;
}

// ---------- model + reference ----------
final _refRe = _re(r'(?<![\p{L}\d])(HR\d{2})[ ]+(\d[\d-]{0,21})(?![\d-])');
final _modelLabel = _re(r'(?<!\p{L})model\p{L}*\s*[:.]?\s*(HR\d{2})(?!\d)');
final _pozivLabel = _re(r'(?<!\p{L})poziv\s+na\s+broj(?:\s+primatelja|\s+odobrenja)?\s*[:.]?\s*(\d[\d-]{0,21})(?![\d-])');

String? _reference(List<String> lines) {
  final found = <String>{};
  String? model, poziv;
  for (final raw in lines) {
    if (_payerLabel.hasMatch(raw)) continue;
    final line = raw.replaceAllMapped(_ibanRe, (m) => ' ' * m[0]!.length);
    for (final m in _refRe.allMatches(line)) {
      final r = normalizeReference(m[1]!, m[2]!);
      if (r != null) found.add(r);
    }
    model ??= _modelLabel.firstMatch(line)?[1];
    poziv ??= _pozivLabel.firstMatch(line)?[1];
  }
  if (found.isEmpty && model != null) {
    final r = normalizeReference(model, poziv ?? '');
    if (r != null) found.add(r);
  }
  return found.length == 1 ? found.first : null;
}

// ---------- total ----------
final _totalLabel =
    _re(r'(?<!\p{L})(ukupno\s+za\s+pla(?:titi|ćanje|canje)|iznos\s+za\s+pla(?:titi|ćanje|canje)|za\s+pla(?:titi|ćanje|canje)'
        r'|sveukupno|ukupno|iznos|total\s+due|amount\s+due|balance\s+due|grand\s+total|total)(?!\p{L})');
final _notPayable =
    _re(r'(?<!\p{L})(bez|excl\p{L}*|subtotal|osnovic\p{L}*|neto|popust\p{L}*|rabat\p{L}*|discount\p{L}*|stavk\p{L}*|kom|komada'
        r'|items?|qty|količin\p{L}*|kolicin\p{L}*|prethodn\p{L}*|previous)(?!\p{L})');
final _tax = _re(r'(?<!\p{L})(pdv|vat|porez\p{L}*|tax)(?!\p{L})');
final _taxIncluded = _re(r'(?<!\p{L})(s|sa|with|incl\.?|including|uklj\.?|uključujući)\s+(pdv|vat|porez\p{L}*|tax)(?!\p{L})');
final _money = _re(r'(?<![\p{L}\d.,:/\-−])(\d{1,3}(?:\.\d{3})+,\d{1,2}|\d{1,3}(?:,\d{3})+\.\d{1,2}|\d{1,12}[.,]\d{1,2}|\d{1,12})'
    r'(?!\d|[.,:/\-]\d|\s?%)');
final _amountLine = _re(r'^\s*(?:€|EUR|HRK|kn)?\s*=?\s*([\d.,]+)\s*(?:€|EUR|HRK|kn)?\s*$');
final _currencyRe = _re(r'(?<!\p{L})(EUR|HRK|USD|GBP|CHF|kn)(?!\p{L})|€');

int? _cents(String s) {
  final sep = s.lastIndexOf(RegExp('[.,]'));
  if (sep < 0) return int.parse(s) * 100;
  final frac = s.substring(sep + 1);
  final whole = s.substring(0, sep).replaceAll(RegExp('[.,]'), '');
  if (frac.length > 2 || whole.isEmpty) return null;
  return int.parse(whole) * 100 + int.parse(frac.padRight(2, '0'));
}

Set<int> _amounts(String s) {
  final out = <int>{};
  for (final m in _money.allMatches(s)) {
    final c = _cents(m[1]!);
    if (c != null) out.add(c);
  }
  return out;
}

(int?, String) _total(List<String> lines) {
  final values = <int>{};
  String? currency;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final m = _totalLabel.firstMatch(line);
    if (m == null || _notPayable.hasMatch(line) || (_tax.hasMatch(line) && !_taxIncluded.hasMatch(line))) continue;
    var found = _amounts(line.substring(m.end));
    var where = line;
    if (found.isEmpty) {
      final next = lines.skip(i + 1).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
      final a = _amountLine.firstMatch(next);
      if (a != null && _money.hasMatch(a[1]!)) {
        found = _amounts(a[1]!);
        where = next;
      }
    }
    if (found.isEmpty) continue;
    values.addAll(found); // two amounts on one line count as two different totals
    final c = _currencyRe.firstMatch(where);
    currency ??= c == null ? null : (c[0] == '€' ? 'EUR' : (c[1]!.toLowerCase() == 'kn' ? 'HRK' : c[1]!.toUpperCase()));
  }
  return values.length == 1 ? (values.first, currency ?? 'EUR') : (null, 'EUR');
}

// ---------- dates ----------
final _dueLabel =
    _re(r'(?<!\p{L})(rok\s+pla[cć]anja|datum\s+dospije[cć]a|dospije[cć]e|due\s+date|payment\s+due|pay\s+by|valuta\s+pla[cć]anja)(?!\p{L})');
final _issueLabel =
    _re(r'(?<!\p{L})(datum\s+ra[cč]una|datum\s+izdavanja(?:\s+ra[cč]una)?|invoice\s+date|issue\s+date|date\s+of\s+issue)(?!\p{L})');
final _plainDateLabel =
    _re(r'(?<!\p{L})(datum(?!\s+(?:dospije|isporuke|valute|pla[cć]anja|ro[dđ]enja|obra[cč]una|ugovora))|date)(?!\p{L})');
final _dateRe = RegExp(r'(?<![\d.])(?:(\d{1,2})\. ?(\d{1,2})\. ?(\d{4})\.?|(\d{4})-(\d{2})-(\d{2}))(?![\d])');

String? _firstDate(String s) {
  final m = _dateRe.firstMatch(s);
  if (m == null) return null;
  return m[1] != null
      ? isoDate(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!))
      : isoDate(int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!));
}

/// The date after the first tier of [labels] that has one (same line, else the next non-empty line); several
/// different dates in that tier → `null`.
String? _labelledDate(List<String> lines, List<RegExp> labels, {RegExp? skip}) {
  for (final label in labels) {
    final found = <String>{};
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      final cut = skip?.firstMatch(line);
      if (cut != null) line = line.substring(0, cut.start); // "Datum računa: … Rok plaćanja: …" on one line
      final m = label.firstMatch(line);
      if (m == null) continue;
      var d = _firstDate(line.substring(m.end));
      if (d == null) {
        final next = lines.skip(i + 1).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '').trimLeft();
        final dm = _dateRe.matchAsPrefix(next);
        if (dm != null) d = _firstDate(next);
      }
      if (d != null) found.add(d);
    }
    if (found.isNotEmpty) return found.length == 1 ? found.first : null;
  }
  return null;
}

// ---------- JIR / ZKI ----------
final _jirRe = _re(r'(?<!\p{L})JIR\s*[:.]?\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?![0-9a-f])');
final _zkiRe = _re(r'(?<!\p{L})ZKI\s*[:.]?\s*([0-9a-f]{32})(?![0-9a-f])');

String? _fiscalId(String t) {
  final jirs = {for (final m in _jirRe.allMatches(t)) m[1]!.toLowerCase()};
  if (jirs.length == 1) return 'jir:${jirs.first}';
  if (jirs.length > 1) return null;
  final zkis = {for (final m in _zkiRe.allMatches(t)) m[1]!.toLowerCase()};
  return zkis.length == 1 ? 'zki:${zkis.first}' : null;
}

// ---------- payee ----------
final _payeeLabel =
    _re(r'^\s*(primatelj|prodavatelj|prodavač|izdavatelj(?:\s+računa)?|seller|supplier|payee|vendor|dobavljač)(?!\p{L})\s*[:\-–]?\s*(.*)$');

final _payeeTail = _re(r'[,;]?\s*(?<!\p{L})(iban|oib|vat|pdv\s+id)(?!\p{L}).*$');

String? _payeeValue(String s) {
  final v = s.replaceFirst(_payeeTail, '').trim().replaceAll(RegExp(r'[\s,;:]+$'), '');
  if (v.isEmpty || v.length > 100 || !RegExp(r'\p{L}', unicode: true).hasMatch(v)) return null;
  if (_payerLabel.hasMatch(v) || _ibanRe.hasMatch(v) || v.contains(':')) return null;
  return v;
}

String? _payee(List<String> lines) {
  for (var i = 0; i < lines.length; i++) {
    final m = _payeeLabel.firstMatch(lines[i]);
    if (m == null) continue;
    final same = m[2]!.trim();
    if (same.isNotEmpty) {
      final v = _payeeValue(same);
      if (v != null) return v;
      continue;
    }
    final next = lines.skip(i + 1).firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    final v = _payeeValue(next);
    if (v != null) return v;
  }
  return null;
}
