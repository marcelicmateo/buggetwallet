// New row ids (`WalletRepo._newId`): many rows made in the same millisecond never share an id. With 20 random bits two
// rows in one millisecond collided about once in a million and merged into one row (the demo seeding lost an IOU once).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

void main() {
  test('rows made back to back get distinct ids and none is lost', () {
    final repo = WalletRepo.inMemory(now: () => DateTime.utc(2026, 10, 5, 12).millisecondsSinceEpoch);
    addTearDown(repo.close);
    final ids = <String>{};
    for (var i = 0; i < 2000; i++) {
      ids.add(repo.addIou(person: 'P$i', direction: IouDirection.lent, amount: 100 + i, currency: 'EUR', date: '2026-10-01'));
    }
    expect(ids, hasLength(2000));
    expect(repo.ious(), hasLength(2000));
  });

  test('an id is the prefix, the clock in base 36 and 14 random base-36 characters', () {
    final repo = WalletRepo.inMemory(now: () => DateTime.utc(2026, 10, 5, 12).millisecondsSinceEpoch);
    addTearDown(repo.close);
    final id = repo.addIou(person: 'Sam', direction: IouDirection.lent, amount: 100, currency: 'EUR', date: '2026-10-01');
    expect(id, matches(RegExp(r'^o[0-9a-z]{8,9}[0-9a-z]{14}$')));
  });
}
