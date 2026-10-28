// M1: invariants of the digest bookkeeping (sync_digest.dart) that survived mutation testing. Synthetic data only.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';
import 'package:wallet_sync/src/sync_digest.dart';

Op rec(Map<String, Object?> f) => Op(digestKind, 's', f, 'h');

void main() {
  group('DigestRecord.fromOp', () {
    test('a well-formed record parses; entries of 0 or less are dropped', () {
      final r = DigestRecord.fromOp(rec({
        'digest': 'ab',
        'vector': {'a': 2, 'b': 0, 'c': -1},
        'schema': 15
      }))!;
      expect(r.digest, 'ab');
      expect(r.vector, {'a': 2});
      expect(r.schema, 15);
    });
    test('each field of the wrong type alone makes it unreadable', () {
      expect(DigestRecord.fromOp(rec({'digest': 1, 'vector': <String, int>{}, 'schema': 1})), isNull);
      expect(DigestRecord.fromOp(rec({'digest': 'x', 'vector': 'no', 'schema': 1})), isNull);
      expect(DigestRecord.fromOp(rec({'digest': 'x', 'vector': <String, int>{}, 'schema': '1'})), isNull);
      expect(DigestRecord.fromOp(rec({'vector': <String, int>{}, 'schema': 1})), isNull);
    });
    test('a vector entry of the wrong type alone (key or value) makes it unreadable', () {
      expect(
          DigestRecord.fromOp(rec({
            'digest': 'x',
            'vector': {'a': 'one'},
            'schema': 1
          })),
          isNull);
      expect(
          DigestRecord.fromOp(rec({
            'digest': 'x',
            'vector': {'a': 1, 'b': 1.5},
            'schema': 1
          })),
          isNull);
      expect(
          DigestRecord.fromOp(rec({
            'digest': 'x',
            'vector': {1: 1},
            'schema': 1
          })),
          isNull);
      expect(
          DigestRecord.fromOp(rec({
            'digest': 'x',
            'vector': {1: 'a'},
            'schema': 1
          })),
          isNull);
    });
  });

  group('sameVector', () {
    test('entries of 0 count as absent, on either side', () {
      expect(sameVector({'a': 1, 'b': 0}, {'a': 1}), isTrue);
      expect(sameVector({'a': 1}, {'a': 1, 'b': 0}), isTrue);
      expect(sameVector({'a': 0}, {}), isTrue);
      expect(sameVector({}, {'a': 0}), isTrue);
    });
    test('different seq or different stream differs', () {
      expect(sameVector({'a': 1}, {'a': 2}), isFalse);
      expect(sameVector({'a': 1}, {'b': 1}), isFalse);
      expect(sameVector({'a': 1}, {}), isFalse);
    });
  });

  group('DigestBook', () {
    test('an empty book has nothing marked', () {
      final b = DigestBook.load(WalletRepo.inMemory());
      expect(b.sendAsk, isFalse);
      expect(b.dirty, isFalse);
      expect(b.vector, isEmpty);
      expect(b.answered, isEmpty);
    });
    test('save then load round-trips every field', () {
      final repo = WalletRepo.inMemory();
      final b = DigestBook.load(repo)
        ..data('s1', 3)
        ..repairAt = 99
        ..send = 'h1'
        ..sendAsk = true
        ..disagree = 'peer'
        ..first = 7
        ..answer('x');
      b.save(repo);
      final c = DigestBook.load(repo);
      expect(c.vector, {'s1': 3});
      expect(c.dirty, isTrue);
      expect(c.repairAt, 99);
      expect(c.send, 'h1');
      expect(c.sendAsk, isTrue);
      expect(c.disagree, 'peer');
      expect(c.first, 7);
      expect(c.answered, ['x']);
    });
    test('data() keeps the highest seq and marks dirty', () {
      final b = DigestBook.load(WalletRepo.inMemory())
        ..data('s', 5)
        ..data('s', 3);
      expect(b.vector['s'], 5);
      expect(b.dirty, isTrue);
    });
    test('load ignores vector entries that are not positive ints, and d other than 1', () {
      final repo = WalletRepo.inMemory();
      repo.setLocalValue(
          DigestBook.key,
          jsonEncode({
            'v': {'a': 0, 'b': 2, 'c': 'x', 'd': -4, 'e': 1.5},
            'd': 0
          }));
      final b = DigestBook.load(repo);
      expect(b.vector, {'b': 2});
      expect(b.dirty, isFalse);
    });
    test('an unreadable value starts over', () {
      final repo = WalletRepo.inMemory();
      repo.setLocalValue(DigestBook.key, '{not json');
      final b = DigestBook.load(repo);
      expect(b.vector, isEmpty);
      expect(b.dirty, isFalse);
    });
    test('answered ids: no duplicates, exactly the newest 32 kept', () {
      final b = DigestBook.load(WalletRepo.inMemory());
      expect(DigestBook.maxAnswered, 32);
      for (var i = 0; i < 32; i++) {
        b.answer('a$i');
      }
      b.answer('a0');
      expect(b.answered.length, 32);
      expect(b.answered.first, 'a0'); // exactly 32 drops nothing
      b.answer('a32');
      expect(b.answered.length, 32);
      expect(b.answered.first, 'a1');
      expect(b.answered.last, 'a32');
      expect(b.answered.contains('a0'), isFalse);
      for (var i = 33; i < 40; i++) {
        b.answer('a$i');
      }
      expect(b.answered, [for (var i = 8; i < 40; i++) 'a$i']);
    });
  });

  test('a second mismatch within 7 days of a repair stops automatic repair', () {
    expect(SyncDigests.repairQuiet, const Duration(days: 7));
  });
}
