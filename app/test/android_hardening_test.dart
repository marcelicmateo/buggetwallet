// Stage H12 / H10 (Android hardening) as a plain unit test over the Android project files. The emulator test cannot ask
// `adb shell dumpsys package` from inside the app, so the facts that decide what Android backs up, which certificate
// authorities the app trusts, how releases are signed and whether the key sheet can be screenshotted are asserted on the
// files that produce them. The assertions are fixed; the ones for H10 carry a plain `BUG: H10` skip that is lifted when the
// platform hardening is merged (they match the files of that change). Synthetic: no data, only project files.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// BW_ANDROID_ROOT points the test at another checkout's android/app (to check the assertions against the platform branch).
final _root = Platform.environment['BW_ANDROID_ROOT'] ?? 'android/app';
String _read(String rel) => File('$_root/$rel').readAsStringSync();


const _domains = [
  'root',
  'file',
  'database',
  'sharedpref',
  'external',
  'device_root',
  'device_file',
  'device_database',
  'device_sharedpref'
];

void main() {
  final manifest = _read('src/main/AndroidManifest.xml');
  final application = RegExp(r'<application\b[^>]*>', dotAll: true).firstMatch(manifest)?.group(0) ?? '';
  String? attr(String name) => RegExp('android:$name\\s*=\\s*"([^"]*)"').firstMatch(application)?.group(1);

  test('the manifest is there and is the app\'s', () {
    expect(manifest, contains('<manifest'));
    expect(application, isNotEmpty);
  });

  group('backup', () {
    test('android:allowBackup is "false": the encrypted database and the key store entry are not copied to a cloud backup or adb backup',
        () {
      expect(attr('allowBackup'), 'false');
    });

    test('data_extraction_rules.xml (Android 12+) excludes every domain, device_* ones included, from cloud backup and device transfer',
        () {
      expect(attr('dataExtractionRules'), '@xml/data_extraction_rules');
      final xml = _read('src/main/res/xml/data_extraction_rules.xml');
      for (final block in ['cloud-backup', 'device-transfer']) {
        final m = RegExp('<$block[^>]*>(.*?)</$block>', dotAll: true).firstMatch(xml);
        expect(m, isNotNull, reason: 'a <$block> section');
        final body = m!.group(1)!;
        expect(body, isNot(contains('<include')), reason: '$block includes nothing');
        for (final d in _domains) {
          expect(body, contains('<exclude domain="$d"'), reason: '$block excludes $d');
        }
      }
    });

    test('backup_rules.xml (Android 11 and older, android:fullBackupContent) excludes every domain too', () {
      expect(attr('fullBackupContent'), '@xml/backup_rules');
      final xml = _read('src/main/res/xml/backup_rules.xml');
      expect(xml, contains('<full-backup-content>'));
      expect(xml, isNot(contains('<include')));
      for (final d in _domains) {
        expect(xml, contains('<exclude domain="$d"'), reason: d);
      }
    });
  });

  group('network', () {
    test('network_security_config.xml trusts the system certificate authorities only: no user-installed CA, no debug override', () {
      expect(attr('networkSecurityConfig'), '@xml/network_security_config');
      final xml = _read('src/main/res/xml/network_security_config.xml');
      final anchors = RegExp(r'<trust-anchors>(.*?)</trust-anchors>', dotAll: true).firstMatch(xml)?.group(1);
      expect(anchors, isNotNull);
      expect(anchors, contains('<certificates src="system"/>'));
      expect(anchors, isNot(contains('src="user"')));
      expect(xml, isNot(contains('debug-overrides')));
      expect(xml, isNot(contains('<pin-set')), reason: 'a pin would lock the owner out of a relay with a renewed certificate');
    });
  });

  group('permissions and components (unchanged by H10, must keep holding)', () {
    test('no storage permissions: files go through the system pickers and app-private folders', () {
      for (final p in ['READ_EXTERNAL_STORAGE', 'WRITE_EXTERNAL_STORAGE', 'MANAGE_EXTERNAL_STORAGE', 'READ_MEDIA_']) {
        expect(manifest, isNot(contains('android.permission.$p')), reason: p);
      }
    });

    test('only the launcher activity is exported; receivers and the camera file provider are not', () {
      for (final m in RegExp(r'<(receiver|provider|service)\b([^>]*)>', dotAll: true).allMatches(manifest)) {
        expect(m.group(2), contains('android:exported="false"'), reason: '${m.group(1)} ${m.group(2)!.split('\n').first.trim()}');
      }
    });

    test('the camera temp folder is app-private: the file provider shares one cache or files folder, never external storage or root', () {
      final xml = _read('src/main/res/xml/bill_photo_paths.xml');
      expect(xml, isNot(contains('external')));
      expect(xml, isNot(contains('root-path')));
      expect(xml, anyOf(contains('<cache-path'), contains('<files-path')));
      expect(manifest, contains('android:grantUriPermissions="true"'));
    });
  });

  group('release signing', () {
    final gradle = _read('build.gradle.kts');
    test('a release build without the release key is refused, and the release build type never signs with the debug key', () {
      final release = RegExp(r'buildTypes\s*\{\s*release\s*\{(.*?)\n        \}', dotAll: true).firstMatch(gradle)?.group(1);
      expect(release, isNotNull);
      expect(release, isNot(contains('"debug"')), reason: 'no debug fallback in the release build type');
      expect(gradle, contains('throw GradleException('));
      expect(gradle, contains('assembleRelease'));
      expect(gradle, contains('BW_KEYSTORE_PASSWORD'));
      expect(gradle, isNot(contains('else "debug"')));
    });
  });

  group('key sheet', () {
    final activity = _read('src/main/kotlin/hr/marcelic/budget_wallet/MainActivity.kt');
    test('MainActivity exposes MethodChannel bw/secure with setSecure(bool) that sets and clears FLAG_SECURE', () {
      expect(activity, contains('"bw/secure"'));
      expect(activity, contains('"setSecure"'));
      expect(activity, contains('window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)'));
      expect(activity, contains('window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)'));
    });
  });
}
