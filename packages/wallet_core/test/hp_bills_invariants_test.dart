// HP-T2: invariants pinned from mutation testing of bills.dart. All data is SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/src/bills.dart';
import 'package:wallet_importer/wallet_importer.dart' show BillItem, BillSource;

void main() {
  test('limits: 5 attachments per payment, 500 items of 200 characters, file types', () {
    expect(maxAttachmentsPerTx, 5);
    expect((maxBillItems, maxBillItemName), (500, 200));
    expect(blobTypes, {'jpg', 'png', 'pdf', 'xml'});
    expect(attachmentTypes, {'jpg', 'png', 'pdf'});
  });

  group('isBlobHash', () {
    final h = 'ab12' * 16;
    test('exactly 64 lowercase hex characters', () {
      expect(isBlobHash(h), isTrue);
      expect(isBlobHash('0' * 64), isTrue);
      expect(isBlobHash('f' * 64), isTrue);
      expect(isBlobHash('a' * 63), isFalse);
      expect(isBlobHash('a' * 65), isFalse);
      expect(isBlobHash(''), isFalse);
      expect(isBlobHash('A' * 64), isFalse);
      expect(isBlobHash('g' * 64), isFalse);
      expect(isBlobHash('${'a' * 63}\n'), isFalse, reason: 'no trailing newline');
      expect(isBlobHash('\n${'a' * 64}'), isFalse);
      expect(isBlobHash('${'a' * 32}-${'a' * 31}'), isFalse);
    });
  });

  group('Bill.idFor', () {
    test('bill: + first 32 hex of the SHA-256, stable and distinct', () {
      // SHA-256("abc") = ba7816bf 8f01cfea 414140de 5dae2223 b00361a3 96177a9c b410ff61 f20015ad
      expect(Bill.idFor('abc'), 'bill:ba7816bf8f01cfea414140de5dae2223');
      expect(Bill.idFor('abc'), Bill.idFor('abc'));
      expect(Bill.idFor('abc'), isNot(Bill.idFor('abd')));
      expect(Bill.idFor('abc').length, 'bill:'.length + 32);
      expect(sha256Hex([]), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });
  });

  group('Bill.fromRow', () {
    test('reads every column; unknown words fall back; wrong types read as null', () {
      final b = Bill.fromRow({
        'id': 'b1',
        'source': 'attachment',
        'status': 'confirmed',
        'external_id': 'e',
        'date': '2026-03-01',
        'due_date': '2026-03-20',
        'payee': 'Shop',
        'iban': 'HR00',
        'reference': 'R',
        'description': 'd',
        'category': 'Shopping',
        'note': 'n',
        'total': 1234,
        'currency': 'USD',
        'items': '[{"name":"Milk","quantity":"2","amount":300}]',
        'unsure': 2,
        'linked_tx': 'tx1',
        'attached_tx': 'tx2',
        'warranty_until': '2027-03-01',
        'return_by': '2026-03-15',
        'blob': 'h',
        'blob_type': 'pdf',
        'blob_bytes': 99,
        'deleted': 1,
      });
      expect((b.id, b.source, b.status), ('b1', BillSource.attachment, BillStatus.confirmed));
      expect((b.externalId, b.date, b.dueDate, b.payee, b.iban, b.reference), ('e', '2026-03-01', '2026-03-20', 'Shop', 'HR00', 'R'));
      expect((b.description, b.category, b.note, b.total, b.currency), ('d', 'Shopping', 'n', 1234, 'USD'));
      expect(b.items.single.name, 'Milk');
      expect(b.items.single.amount, 300);
      expect((b.unsure, b.linkedTx, b.attachedTx, b.warrantyUntil, b.returnBy), (2, 'tx1', 'tx2', '2027-03-01', '2026-03-15'));
      expect((b.blob, b.blobType, b.blobBytes, b.deleted), ('h', 'pdf', 99, true));
      expect(b.file!.hash, 'h');
      expect(b.file!.bytes, 99);
      expect(b.isAttachment, isTrue);
      expect(b.confirmed, isTrue);
    });

    test('defaults: unknown source and status, missing currency, damaged items, deleted only for 1', () {
      final b = Bill.fromRow(
          {'id': 'b2', 'source': 'future', 'status': 'future', 'items': 'not json', 'total': '5', 'unsure': null, 'deleted': 0});
      expect(b.source, BillSource.manual);
      expect(b.status, BillStatus.review);
      expect(b.currency, 'EUR');
      expect(b.items, isEmpty);
      expect(b.total, isNull);
      expect(b.unsure, 0);
      expect(b.deleted, isFalse);
      expect(b.file, isNull);
      expect(Bill.fromRow({'id': 'b3', 'deleted': 2}).deleted, isFalse);
      expect(Bill.fromRow({'id': 'b3', 'deleted': true}).deleted, isFalse);
      expect(Bill.fromRow({'id': 'b3', 'blob': 'h'}).file, isNull, reason: 'a file needs a type too');
      expect(Bill.fromRow({'id': 'b3', 'blob': 'h', 'blob_type': 'pdf'}).file!.bytes, 0);
    });

    test('title: payee, else Bill (blank counts as none)', () {
      expect(Bill.fromRow({'id': 'x', 'payee': 'Shop'}).title, 'Shop');
      expect(Bill.fromRow({'id': 'x', 'payee': '  '}).title, 'Bill');
      expect(Bill.fromRow({'id': 'x'}).title, 'Bill');
    });
  });

  group('bill items', () {
    test('limits are inclusive: 500 items and 200-character names fit, one more does not', () {
      expect(encodeBillItems([for (var i = 0; i < 500; i++) BillItem(name: 'a', amount: 1)]), isNotNull);
      expect(encodeBillItems([for (var i = 0; i < 501; i++) BillItem(name: 'a', amount: 1)]), isNull);
      expect(encodeBillItems([BillItem(name: 'a' * 200, amount: 1)]), isNotNull);
      expect(encodeBillItems([BillItem(name: 'a' * 201, amount: 1)]), isNull);
      expect(decodeBillItems('[${List.filled(500, '{"name":"a","amount":1}').join(',')}]'), hasLength(500));
      expect(decodeBillItems('[${List.filled(501, '{"name":"a","amount":1}').join(',')}]'), isNull);
      expect(decodeBillItems('[{"name":"${'a' * 200}","amount":1}]'), isNotNull);
      expect(decodeBillItems('[{"name":"${'a' * 201}","amount":1}]'), isNull);
    });

    test('shape: int amounts, string or missing quantity, list of maps', () {
      expect(decodeBillItems('[]'), isEmpty);
      expect(decodeBillItems('[{"name":"a","amount":1.5}]'), isNull);
      expect(decodeBillItems('[{"name":"a","amount":"1"}]'), isNull);
      expect(decodeBillItems('[{"name":"a","quantity":2,"amount":1}]'), isNull);
      expect(decodeBillItems('[{"name":"a","quantity":null,"amount":1}]')!.single.quantity, isNull);
      expect(decodeBillItems('[{"name":1,"amount":1}]'), isNull);
      expect(decodeBillItems('[1]'), isNull);
      expect(decodeBillItems('{}'), isNull);
      expect(decodeBillItems(5), isNull);
      expect(decodeBillItems(null), isNull);
    });
  });
}
