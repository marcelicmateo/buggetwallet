// UBL 2.1 e-invoice reader (EN 16931 / Croatian CIUS). Reads only the fields a bill needs.
import 'package:logging/logging.dart';
import 'package:xml/xml.dart';

import '../log.dart';
import 'common.dart';
import 'model.dart';

const _invoiceNs = 'urn:oasis:names:specification:ubl:schema:xsd:Invoice-2';
const _creditNs = 'urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2';

/// Largest e-invoice read (characters); bigger → `null`.
const maxEInvoiceChars = 5 * 1024 * 1024;

/// Most invoice lines kept; the rest are counted in the log and dropped.
const maxEInvoiceItems = 2000;

/// Reads a UBL 2.1 `Invoice`: number, issue and due date, supplier, payee account, payment reference, payable total and
/// lines. Amounts are converted to cents from their decimal text (never through a double). A `CreditNote`, any other
/// root, malformed XML, a DOCTYPE/entity declaration or more than [maxEInvoiceChars] → `null`.
///
/// `externalId` is `inv:<supplier VAT/company id, else IBAN>:<invoice number>` when both are present.
/// An account that fails the IBAN checksum is dropped (`unsure` + 1); a line whose amount is not exact cents is dropped.
NormalizedBill? readEInvoice(String xml) {
  final fields = <String, Object?>{'chars': xml.length};
  NormalizedBill? bill;
  try {
    bill = _read(xml, fields);
  } catch (_) {
    fields['reason'] = 'malformed';
  }
  fields['ok'] = bill != null;
  logImporter(billsLog, bill == null ? Level.INFO : Level.FINE, 'bills.invoice', fields);
  return bill;
}

NormalizedBill? _read(String xml, Map<String, Object?> log) {
  if (xml.length > maxEInvoiceChars) {
    log['reason'] = 'tooBig';
    return null;
  }
  // UBL never needs a DTD: refusing one rules out entity expansion and external entities.
  if (RegExp(r'<!(DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(xml)) {
    log['reason'] = 'doctype';
    return null;
  }
  final root = XmlDocument.parse(xml).rootElement;
  if (root.name.local == 'CreditNote' && root.namespaceUri == _creditNs) {
    log['reason'] = 'creditNote';
    return null;
  }
  if (root.name.local != 'Invoice' || root.namespaceUri != _invoiceNs) {
    log['reason'] = 'notInvoice';
    return null;
  }
  var unsure = 0;
  final number = _text(root, ['ID']);
  final date = checkIso(_text(root, ['IssueDate']));
  final dueDate = checkIso(_text(root, ['DueDate'])) ??
      checkIso(_text(root, ['PaymentMeans', 'PaymentDueDate'])) ??
      checkIso(_text(root, ['PaymentTerms', 'PaymentDueDate']));
  final party = _path(root, ['AccountingSupplierParty', 'Party']);
  final payee = party == null ? null : _text(party, ['PartyName', 'Name']) ?? _text(party, ['PartyLegalEntity', 'RegistrationName']);
  final supplierId = party == null
      ? null
      : _text(party, ['PartyTaxScheme', 'CompanyID']) ??
          _text(party, ['PartyLegalEntity', 'CompanyID']) ??
          _text(party, ['EndpointID']) ??
          _text(party, ['PartyIdentification', 'ID']);

  String? iban;
  String? reference;
  for (final means in _children(root, 'PaymentMeans')) {
    final account = _text(means, ['PayeeFinancialAccount', 'ID']);
    if (iban == null && account != null) {
      final s = account.replaceAll(' ', '').toUpperCase();
      if (validIban(s)) {
        iban = s;
      } else {
        unsure++;
      }
    }
    final pid = _text(means, ['PaymentID']);
    final m = pid == null ? null : RegExp(r'^(HR\d{2})\s*([0-9-]*)$', caseSensitive: false).firstMatch(pid);
    if (reference == null && m != null) reference = normalizeReference(m[1]!, m[2]!);
  }

  final payable = _path(root, ['LegalMonetaryTotal', 'PayableAmount']);
  final total = payable == null ? null : decimalCents(payable.innerText);
  final currency = (payable?.getAttribute('currencyID') ?? _text(root, ['DocumentCurrencyCode']) ?? 'EUR').trim().toUpperCase();

  final items = <BillItem>[];
  var dropped = 0;
  for (final line in _children(root, 'InvoiceLine')) {
    final amount = _text(line, ['LineExtensionAmount']);
    final cents = amount == null ? null : decimalCents(amount);
    if (cents == null || items.length >= maxEInvoiceItems) {
      dropped++;
      continue;
    }
    items.add(BillItem(
      name: _text(line, ['Item', 'Name']) ?? _text(line, ['Item', 'Description']) ?? '',
      quantity: _text(line, ['InvoicedQuantity']),
      amount: cents,
    ));
  }
  log.addAll({'items': items.length, 'dropped': dropped});
  if (number == null && total == null) {
    log['reason'] = 'empty';
    return null;
  }
  final idPart = supplierId?.replaceAll(' ', '') ?? iban;
  return NormalizedBill(
    source: BillSource.eInvoice,
    externalId: idPart != null && number != null ? 'inv:$idPart:$number' : null,
    date: date,
    dueDate: dueDate,
    payee: payee,
    iban: iban,
    reference: reference,
    total: total,
    currency: RegExp(r'^[A-Z]{3}$').hasMatch(currency) ? currency : 'EUR',
    items: items,
    unsure: unsure,
  );
}

Iterable<XmlElement> _children(XmlElement e, String local) => e.childElements.where((c) => c.name.local == local);

XmlElement? _path(XmlElement e, List<String> path) {
  XmlElement? cur = e;
  for (final p in path) {
    cur = cur == null ? null : _children(cur, p).firstOrNull;
  }
  return cur;
}

String? _text(XmlElement e, List<String> path) {
  final t = _path(e, path)?.innerText.trim();
  return t == null || t.isEmpty ? null : t;
}
