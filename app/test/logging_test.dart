import 'dart:io';

import 'package:budget_wallet/src/logging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_core/wallet_core.dart';

void main() {
  test('appVersion matches pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.substring('version:'.length).trim(), appVersion);
  });

  test('fileExt gives only the extension, never the name', () {
    expect(fileExt('Izvod PBZ ožujak.XLS'), 'xls');
    expect(fileExt('account-statement_2026.csv'), 'csv');
    expect(fileExt('statement'), '');
    expect(fileExt('weird.name with spaces'), 'other');
    expect(fileExt('archive.tar.gz'), 'gz');
  });

  test('log levels', () {
    AppLog.setLevel('warning');
    expect(Logger.root.level, Level.WARNING);
    AppLog.setLevel('info');
    expect(Logger.root.level, Level.INFO);
    AppLog.setLevel(null);
    expect(Logger.root.level, Level.ALL);
    AppLog.setLevel('nonsense');
    expect(Logger.root.level, Level.ALL);
  });

  test('nav events and routes log names and result words only', () async {
    Logger.root.level = Level.ALL;
    final lines = <String>[];
    final sub = Logger.root.onRecord.listen((r) => lines.add(formatLogRecord(r)));
    addTearDown(sub.cancel);
    logNav('nav.tab', {'from': 'today', 'to': 'plan'});
    expect(await loggedRoute('TxSheet', Future.value('saved')), 'saved');
    expect(await loggedRoute<Object>('GoalSheet', Future.value(const Duration(seconds: 1))), isA<Duration>());
    expect(lines[0], endsWith(' INFO bw.nav nav.tab {"from":"today","to":"plan"}'));
    expect(lines[1], endsWith(' bw.nav sheet.open {"sheet":"TxSheet"}'));
    expect(lines[2], endsWith(' bw.nav sheet.close {"sheet":"TxSheet","result":"saved"}'));
    expect(lines[4], endsWith(' bw.nav sheet.close {"sheet":"GoalSheet","result":"Duration"}'));
  });
}
