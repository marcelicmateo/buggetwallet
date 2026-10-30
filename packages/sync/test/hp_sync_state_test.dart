// HP-T1: RelayState.fromJson boundaries (the relay's answer is untrusted input). All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_sync/wallet_sync.dart';

void main() {
  test('usage numbers: 0 is a value, negative or non-int is unknown', () {
    final s = RelayState.fromJson({'bytes': 0, 'maxBytes': 0});
    expect((s.bytes, s.maxBytes), (0, 0));
    final t = RelayState.fromJson({'bytes': -1, 'maxBytes': 1.5});
    expect((t.bytes, t.maxBytes), (null, null));
    final u = RelayState.fromJson({'bytes': '5', 'maxBytes': 7});
    expect((u.bytes, u.maxBytes), (null, 7));
    final v = RelayState.fromJson(<String, Object?>{});
    expect((v.bytes, v.maxBytes), (null, null));
  });

  test('instance: 32 lowercase hex or absent; anything else rejects the whole state', () {
    final ok = 'ab' * 16;
    expect(RelayState.fromJson({'instance': ok}).instance, ok);
    expect(RelayState.fromJson({'instance': null}).instance, isNull);
    for (final bad in <Object?>['AB' * 16, 'ab' * 15, 'ab' * 17, '${'ab' * 15}zz', 5, '${ok}x', 'x$ok']) {
      expect(() => RelayState.fromJson({'instance': bad}), throwsFormatException, reason: '$bad');
    }
  });

  test('devices and snapshots: bad shapes throw, good ones keep first/last/acks/covers', () {
    final s = RelayState.fromJson({
      'devices': {
        'd1': {
          'first': 0,
          'last': 3,
          'lastSeen': '2026-10-01T00:00:00Z',
          'acks': {'d2': 2}
        },
        'd2': {'first': 1, 'last': 1, 'lastSeen': 'not a date'},
      },
      'snapshot': {
        'id': 's1',
        'covers': {'d1': 3}
      },
      'previous': null,
      'api': 5,
      'locked': true,
    });
    expect((s.devices['d1']!.first, s.devices['d1']!.last), (0, 3));
    expect(s.devices['d1']!.acks, {'d2': 2});
    expect(s.devices['d1']!.lastSeen, DateTime.utc(2026, 10, 1));
    expect(s.devices['d2']!.lastSeen, isNull);
    expect(s.devices['d2']!.acks, isEmpty);
    expect(s.snapshot!.id, 's1');
    expect(s.snapshot!.covers, {'d1': 3});
    expect(s.previous, isNull);
    expect((s.api, s.locked), (5, true));
    expect(RelayState.fromJson({'api': '5', 'locked': 1}).api, isNull);
    expect(RelayState.fromJson({'api': '5', 'locked': 1}).locked, isNull);
    for (final bad in <Object?>[
      [],
      {'devices': <Object?>[]},
      {
        'devices': {
          'd': {'first': 'x', 'last': 1}
        }
      },
      {
        'devices': {
          'd': {'first': 1}
        }
      },
      {
        'devices': {
          'd': {
            'first': 1,
            'last': 1,
            'acks': {'x': 'y'}
          }
        }
      },
      {
        'devices': {
          'd': {'first': 1, 'last': 1, 'acks': <Object?>[]}
        }
      },
      {'snapshot': 'x'},
      {
        'snapshot': {'covers': <String, Object?>{}}
      },
      {'keys': <String, Object?>{}},
      {'pending': 'x'},
      {
        'keys': [
          {'fp': 5}
        ]
      },
    ]) {
      expect(() => RelayState.fromJson(bad), throwsFormatException, reason: '$bad');
    }
  });

  test('keys and pending: defaults when fields are absent', () {
    final s = RelayState.fromJson({
      'keys': [
        {'fp': 'aa'},
        {'fp': 'bb', 'by': 'dev', 'self': true, 'deviceId': 'x', 'device': 'Phone', 'revoked': '2026-10-02T00:00:00Z'}
      ],
      'pending': [
        {'fp': 'cc', 'at': '2026-10-03T00:00:00Z', 'deviceId': 'y'}
      ],
    });
    expect(s.keys!.map((k) => k.fp), ['aa', 'bb']);
    expect((s.keys![0].by, s.keys![0].self, s.keys![0].revoked, s.keys![0].deviceId), ('wallet', false, null, null));
    expect((s.keys![1].by, s.keys![1].self, s.keys![1].deviceId, s.keys![1].device), ('dev', true, 'x', 'Phone'));
    expect(s.keys![1].revoked, DateTime.utc(2026, 10, 2));
    expect((s.pending.single.fp, s.pending.single.at, s.pending.single.deviceId), ('cc', DateTime.utc(2026, 10, 3), 'y'));
    expect(RelayState.fromJson(<String, Object?>{}).keys, isNull);
    expect(RelayState.fromJson(<String, Object?>{}).pending, isEmpty);
  });
}
