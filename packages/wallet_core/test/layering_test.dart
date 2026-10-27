// J4 layering: wallet_sync builds on wallet_core, never the other way. Core's tests use the sync engine (dev
// dependency, test/support/sim.dart), so this checks that lib/ and the regular dependencies never reach it.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('lib/ and tool/ never import package:wallet_sync', () {
    final offenders = [
      for (final dir in ['lib', 'tool'])
        for (final f in Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')))
          if (f.readAsStringSync().contains('package:wallet_sync/')) f.path,
    ];
    expect(offenders, isEmpty);
  });

  test('wallet_sync is a dev dependency only', () {
    final pubspec = File('pubspec.yaml').readAsLinesSync();
    final deps = pubspec.indexOf('dependencies:'), dev = pubspec.indexOf('dev_dependencies:');
    expect(deps, greaterThanOrEqualTo(0));
    expect(dev, greaterThan(deps));
    expect(pubspec.sublist(deps, dev).where((l) => l.trim().startsWith('wallet_sync')), isEmpty);
    expect(pubspec.sublist(dev).where((l) => l.trim().startsWith('wallet_sync')), hasLength(1));
  });
}
