// J4 layering: wallet_sync builds on wallet_core, never the other way. Core's tests use the sync engine (dev
// dependency, test/support/sim.dart), so this checks that lib/ and the regular dependencies never reach it.
import 'dart:io';

import 'package:test/test.dart';

/// The URI of every import, export and part directive in [source] (`part of` excluded).
Iterable<String> directiveUris(String source) =>
    RegExp(r"^\s*(?:import|export|part)\s+'([^']+)'", multiLine: true).allMatches(source).map((m) => m.group(1)!);

/// Whether [uri], written in the file at [from], names wallet_sync: its package URI, or a relative path into
/// `packages/sync/lib/`.
bool reachesSync(Uri from, String uri) =>
    uri.startsWith('package:wallet_sync/') ||
    (!uri.contains(':') && from.resolve(uri).path.startsWith(Directory.current.uri.resolve('../sync/lib/').path));

void main() {
  test('lib/ and tool/ never import, export or part wallet_sync (package URI or relative path)', () {
    final offenders = [
      for (final dir in ['lib', 'tool'])
        for (final f in Directory(dir).listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')))
          for (final uri in directiveUris(f.readAsStringSync()))
            if (reachesSync(f.absolute.uri, uri)) '${f.path}: $uri',
    ];
    expect(offenders, isEmpty);
  });

  test('the check sees package URIs and relative paths into sync/lib, and nothing else', () {
    final from = File('lib/src/logs.dart').absolute.uri;
    final uris = directiveUris(
      "import 'package:wallet_sync/wallet_sync.dart';\nexport '../../../sync/lib/src/sync.dart';\npart '../../../sync/lib/x.dart';\n"
      "import 'vault.dart';\nimport '../../../sync/test/x.dart';\npart of 'repo.dart';\n",
    ).toList();
    expect(uris, hasLength(5));
    expect([for (final u in uris) reachesSync(from, u)], [true, true, true, false, false]);
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
