// Start-up with the encrypted local database (R6b): the database opens only once the key is known, before that the controller
// runs on an in-memory placeholder, and an older database file is never deleted or overwritten. The file system is replaced by a
// fake "world" that knows which key the file on disk needs. All data is SYNTHETIC.
import 'dart:typed_data';

import 'package:budget_wallet/src/controller.dart';
import 'package:budget_wallet/src/key_store.dart' show WrongPassphrase;
import 'package:budget_wallet/src/screens/onboarding.dart';
import 'package:budget_wallet/src/wallet_db.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

import 'support/wallet.dart';

/// The wallet file on a fake disk: absent, plaintext, or encrypted with [fileKey]; plus the files set aside.
class World {
  bool hasFile;
  Uint8List? fileKey; // null = plaintext
  WalletRepo? contents;
  final aside = <String, WalletRepo?>{};
  final opens = <Uint8List>[];
  int existsCalls = 0;
  int forgets = 0;
  Object? openError;

  World({this.hasFile = false, this.fileKey}) {
    if (hasFile) contents = _seeded();
  }

  static WalletRepo _seeded() {
    final r = WalletRepo.inMemory();
    r.saveGoal(name: 'Old goal', target: 100000, saved: 0, monthly: 1000, sort: 1);
    return r;
  }

  Future<WalletDb> open(Uint8List dbKey) async {
    opens.add(dbKey);
    if (openError != null) Error.throwWithStackTrace(openError!, StackTrace.current);
    var converted = false;
    if (hasFile) {
      if (fileKey != null && !_same(fileKey!, dbKey)) throw const WalletDbKeyException('the key does not open this database');
      converted = fileKey == null;
    } else {
      hasFile = true;
      contents = WalletRepo.inMemory();
    }
    fileKey = dbKey;
    return WalletDb(contents!, converted: converted, forget: () async {
      forgets++;
      hasFile = false;
      contents = null;
    });
  }

  Future<bool> exists() async {
    existsCalls++;
    return hasFile;
  }

  /// What happened, in order: 'aside' and 'key'.
  final events = <String>[];

  Future<bool> isPlaintext() async => hasFile && fileKey == null;

  Future<void> setAside(String stamp) async {
    events.add('aside');
    aside['wallet.db.unopened-$stamp'] = contents;
    hasFile = false;
    contents = null;
    fileKey = null;
  }

  static bool _same(List<int> a, List<int> b) => a.length == b.length && Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
}

Future<WalletController> loadWith(
  World w, {
  VaultKey? key,
  bool locked = false,
  Object? keyError,
  Future<void> Function()? claim,
  bool autoDispose = true,
}) async {
  final wc = await WalletController.load(
    opener: w.open,
    exists: w.exists,
    setAside: w.setAside,
    isPlaintext: w.isPlaintext,
    claim: claim ?? () async {},
    keyReader: () async => keyError != null ? Error.throwWithStackTrace(keyError, StackTrace.current) : key,
    isLocked: () => locked,
    clock: () => DateTime(2026, 10, 22, 12),
  );
  await Future<void>.delayed(Duration.zero); // lets the start-up microtasks (nudges, recurring) run
  if (autoDispose) addTearDown(wc.dispose);
  wc.keyWriter = (k, {passphrase}) async => w.events.add('key');
  wc.keyForgetter = () async {};
  wc.unlocker = (p) async => throw const WrongPassphrase();
  return wc;
}

void main() {
  late List<String> lines;
  setUp(() {
    Logger.root.level = Level.ALL;
    lines = [];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
  });

  String log() => lines.join('\n');

  group('a key is stored', () {
    test('opens the keyed database with localDbKey(key) and shows its data', () async {
      final key = VaultKey.generate();
      final w = World(hasFile: true, fileKey: await localDbKey(key));
      final wc = await loadWith(w, key: key);
      expect(wc.hasWallet, isTrue);
      expect(wc.hasUnopenedDb, isFalse);
      expect(w.opens, hasLength(1));
      expect(w.opens.single, await localDbKey(key));
      expect(wc.goals.single.name, 'Old goal');
      expect(w.existsCalls, 0);
      expect(log(), contains('db.open'));
      expect(log(), contains('"keyed":true'));
      expect(log(), contains('"converted":false'));
    });

    test('an older plaintext file is converted on this start and logged as converted', () async {
      final key = VaultKey.generate();
      final w = World(hasFile: true); // plaintext
      final wc = await loadWith(w, key: key);
      expect(wc.hasWallet, isTrue);
      expect(wc.goals.single.name, 'Old goal');
      expect(w.fileKey, await localDbKey(key));
      expect(log(), contains('"converted":true'));
    });

    test('a key that does not open the file: nothing is deleted or set aside, onboarding with the notice flag', () async {
      final w = World(hasFile: true, fileKey: await localDbKey(VaultKey.generate()));
      final wc = await loadWith(w, key: VaultKey.generate());
      expect(wc.hasWallet, isFalse);
      expect(wc.hasUnopenedDb, isTrue);
      expect(w.hasFile, isTrue);
      expect(w.aside, isEmpty);
      expect(w.forgets, 0);
      expect(wc.goals, isEmpty); // the placeholder, not the file
    });

    test('another failure from the opener is not swallowed', () async {
      final w = World()..openError = StateError('disk');
      await expectLater(loadWith(w, key: VaultKey.generate()), throwsStateError);
    });

    test('the log never holds key bytes', () async {
      final key = VaultKey.generate();
      final w = World(hasFile: true, fileKey: await localDbKey(key));
      await loadWith(w, key: key);
      final hex = (await localDbKey(key)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(log(), isNot(contains(hex)));
      expect(log(), isNot(contains(await key.toText())));
    });
  });

  group('no key yet', () {
    test('runs on an in-memory placeholder: the opener is not called, the file is only looked for', () async {
      final w = World();
      final wc = await loadWith(w);
      expect(wc.hasWallet, isFalse);
      expect(wc.hasUnopenedDb, isFalse);
      expect(w.opens, isEmpty);
      expect(w.existsCalls, 1);
    });

    test('create opens a new keyed database and switches to it (default goals land in it)', () async {
      final w = World();
      final wc = await loadWith(w);
      final placeholder = wc.repo;
      await wc.createWallet();
      expect(w.opens, hasLength(1));
      expect(w.opens.single, await localDbKey(wc.key!));
      expect(wc.repo, isNot(same(placeholder)));
      expect(wc.repo, same(w.contents));
      expect(wc.goals, hasLength(2));
      expect(w.aside, isEmpty);
    });

    test('an older file and no key: the notice flag is set, nothing is opened, deleted or moved', () async {
      final w = World(hasFile: true, fileKey: await localDbKey(VaultKey.generate()));
      final wc = await loadWith(w);
      expect(wc.hasUnopenedDb, isTrue);
      expect(w.opens, isEmpty);
      expect(w.aside, isEmpty);
      expect(w.hasFile, isTrue);
    });

    test('creating a new wallet sets the older file aside first and logs db.setAside without a path', () async {
      final oldKey = await localDbKey(VaultKey.generate());
      final w = World(hasFile: true, fileKey: oldKey);
      final old = w.contents;
      final wc = await loadWith(w);
      await wc.createWallet();
      expect(w.aside.keys, ['wallet.db.unopened-2026-10-22']);
      expect(w.aside.values.single, same(old)); // the old data is still there
      expect(w.fileKey, await localDbKey(wc.key!));
      expect(wc.goals.map((g) => g.name), isNot(contains('Old goal')));
      expect(wc.hasUnopenedDb, isFalse);
      expect(log(), contains('db.setAside'));
      expect(log(), isNot(contains('unopened-2026')));
    });

    test('joining with the key that opens the older file uses it, nothing is set aside', () async {
      final key = VaultKey.generate();
      final w = World(hasFile: true, fileKey: await localDbKey(key));
      final wc = await loadWith(w);
      await wc.joinWallet(await key.toText());
      expect(w.aside, isEmpty);
      expect(wc.goals.single.name, 'Old goal');
      expect(wc.hasWallet, isTrue);
      expect(wc.hasUnopenedDb, isFalse);
    });

    test('joining with a key while an unkeyed plaintext file exists sets it aside: not converted, not merged', () async {
      final w = World(hasFile: true); // plaintext, no key stored
      final old = w.contents;
      final wc = await loadWith(w);
      expect(wc.hasUnopenedDb, isTrue);
      await wc.joinWallet(await VaultKey.generate().toText());
      expect(w.aside.values.single, same(old), reason: 'the old file is kept as it was');
      expect(w.opens, hasLength(1), reason: 'only the fresh database was opened, never the plaintext file');
      expect(wc.goals.map((g) => g.name), isNot(contains('Old goal')));
      expect(wc.hasWallet, isTrue);
      expect(wc.hasUnopenedDb, isFalse);
      expect(log(), contains('"converted":false'));
      expect(log(), isNot(contains('"converted":true')));
    });

    test('join and create set the older file aside before the key is written', () async {
      final w = World(hasFile: true);
      final wc = await loadWith(w);
      await wc.joinWallet(await VaultKey.generate().toText());
      expect(w.events, ['aside', 'key']);

      final w2 = World(hasFile: true);
      final wc2 = await loadWith(w2);
      await wc2.createWallet();
      expect(w2.events, ['aside', 'key']);
    });

    test('joining with another key sets the older file aside and starts a new database', () async {
      final w = World(hasFile: true, fileKey: await localDbKey(VaultKey.generate()));
      final wc = await loadWith(w);
      await wc.joinWallet(await VaultKey.generate().toText());
      expect(w.aside, hasLength(1));
      expect(wc.goals, isEmpty);
      expect(wc.hasWallet, isTrue);
      expect(log(), contains('db.setAside'));
    });

    test('joining with a relay address saves it in the file database', () async {
      final w = World();
      final wc = await loadWith(w);
      wc.syncRunner = (relay, key, repo) async => throw StateError('offline');
      await wc.joinWallet(await VaultKey.generate().toText(), relay: Uri.parse('http://homeserver:8787'));
      expect(wc.repo.localValue('relayUrl'), 'http://homeserver:8787');
      expect(wc.relayUrl, Uri.parse('http://homeserver:8787'));
    });

    test('a bad key text opens nothing', () async {
      final w = World();
      final wc = await loadWith(w);
      await expectLater(wc.joinWallet('not a key'), throwsA(anything));
      expect(w.opens, isEmpty);
      expect(wc.hasWallet, isFalse);
    });
  });

  group('web: locked', () {
    test('a locked start neither asks for the file nor opens it; unlock opens the keyed database', () async {
      final key = VaultKey.generate();
      final w = World(hasFile: true, fileKey: await localDbKey(key));
      final wc = await loadWith(w, locked: true);
      expect(wc.locked, isTrue);
      expect(w.existsCalls, 0);
      expect(w.opens, isEmpty);
      wc.unlocker = (p) async => key;
      await wc.unlock('right passphrase');
      expect(wc.locked, isFalse);
      expect(wc.hasWallet, isTrue);
      expect(wc.goals.single.name, 'Old goal');
      expect(w.aside, isEmpty);
    });

    test('unlock with a key that does not open the file keeps the file and goes to onboarding', () async {
      final w = World(hasFile: true, fileKey: await localDbKey(VaultKey.generate()));
      final wc = await loadWith(w, locked: true);
      wc.unlocker = (p) async => VaultKey.generate();
      await wc.unlock('right passphrase');
      expect(wc.locked, isFalse);
      expect(wc.hasWallet, isFalse);
      expect(wc.hasUnopenedDb, isTrue);
      expect(w.aside, isEmpty);
      expect(w.hasFile, isTrue);
    });
  });

  group('onboarding notice', () {
    /// Loads on real async (key derivation, start-up microtasks) and returns the controller; the caller disposes it.
    Future<WalletController> startUp(WidgetTester t, {required bool older}) async {
      final wc = await t.runAsync(() async {
        final w = older ? World(hasFile: true, fileKey: await localDbKey(VaultKey.generate())) : World();
        return loadWith(w, autoDispose: false);
      });
      return wc!;
    }

    Future<void> finish(WidgetTester t, WalletController wc) async {
      await t.pumpWidget(const SizedBox());
      wc.dispose();
    }

    for (final (name, size, scale) in [('phone 320 dp at 2.0', const Size(320, 2400), 2.0), ('desktop', const Size(1280, 800), 1.0)]) {
      testWidgets('an older wallet on the device is announced ($name)', (t) async {
        final wc = await startUp(t, older: true);
        await pumpApp(t, OnboardingScreen(wc: wc), size: size, textScale: scale);
        expect(find.byKey(const ValueKey('olderWalletNotice')), findsOneWidget);
        expect(find.text('An older wallet is on this device. Join with its key to open it.'), findsOneWidget);
        expect(t.takeException(), isNull); // an overflow would show up here
        await finish(t, wc);
      });
    }

    testWidgets('no notice without an older file', (t) async {
      final wc = await startUp(t, older: false);
      await pumpApp(t, OnboardingScreen(wc: wc));
      expect(find.byKey(const ValueKey('olderWalletNotice')), findsNothing);
      await finish(t, wc);
    });
  });
  group('forget, then a new wallet', () {
    test('forget leaves the placeholder; creating again opens a fresh keyed database', () async {
      final key = VaultKey.generate();
      final w = World(hasFile: true, fileKey: await localDbKey(key));
      final wc = await loadWith(w, key: key);
      await wc.forgetBrowser();
      expect(w.forgets, 1);
      expect(wc.hasWallet, isFalse);
      expect(wc.goals, isEmpty);
      expect(w.opens, hasLength(1)); // forget did not open another database
      await wc.createWallet();
      expect(w.opens, hasLength(2));
      expect(w.opens.last, await localDbKey(wc.key!));
      expect(wc.repo, same(w.contents));
      expect(wc.goals, hasLength(2));
    });
  });
}
