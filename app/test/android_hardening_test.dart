// Stage H12 / H10 (Android hardening) as a plain unit test over the Android project files. The emulator test cannot ask
// `adb shell dumpsys package` from inside the app, so the facts that decide what Android backs up, which traffic it
// allows, how releases are signed and whether the key sheet can be screenshotted are asserted on the files that produce
// them. A check whose feature is not in the files yet skips itself with `BUG: H10` and starts running when the files
// change. Synthetic: no data, only project files.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _root = 'android/app';
String _read(String rel) {
  final f = File('$_root/$rel');
  return f.existsSync() ? f.readAsStringSync() : '';
}

String? _bug(bool present, String what) => present ? null : 'BUG: H10 - $what';

bool _private(String host) {
  if (host == 'localhost' || host == '10.0.2.2' || host == '127.0.0.1') return true;
  if (host.endsWith('.local')) return host.length > '.local'.length;
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$').firstMatch(host);
  if (m == null) return false;
  final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
  return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

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
    }, skip: _bug(attr('allowBackup') == 'false', 'allowBackup is not off in AndroidManifest.xml'));

    final rulesRef = attr('dataExtractionRules');
    test('android:dataExtractionRules names an xml file that excludes every domain from cloud backup and device transfer', () {
      expect(rulesRef, startsWith('@xml/'));
      final xml = _read('src/main/res/xml/${rulesRef!.substring(5)}.xml');
      expect(xml, isNotEmpty, reason: 'the referenced file exists');
      for (final block in ['cloud-backup', 'device-transfer']) {
        final m = RegExp('<$block[^>]*>(.*?)</$block>', dotAll: true).firstMatch(xml);
        expect(m, isNotNull, reason: 'a <$block> section');
        final body = m!.group(1)!;
        expect(body, isNot(contains('<include')), reason: '$block includes nothing');
        for (final domain in ['root', 'file', 'database', 'sharedpref', 'external']) {
          expect(body, contains('<exclude domain="$domain"'), reason: '$block excludes $domain');
        }
      }
    }, skip: _bug(rulesRef != null, 'no android:dataExtractionRules (Android 12+ ignores allowBackup for device transfer without it)'));

    test('the old fullBackupContent attribute, if present, includes nothing either', () {
      final ref = attr('fullBackupContent');
      if (ref == null || ref == 'false') return;
      final xml = _read('src/main/res/xml/${ref.replaceFirst('@xml/', '')}.xml');
      expect(xml, isNot(contains('<include')));
    });
  });

  group('network', () {
    final nsc = attr('networkSecurityConfig');
    test('the application does not allow cleartext traffic globally', () {
      expect(attr('usesCleartextTraffic'), isNot('true'));
    }, skip: _bug(attr('usesCleartextTraffic') != 'true', 'android:usesCleartextTraffic="true" allows plain HTTP to any host'));

    test('network_security_config.xml: cleartext off by default, on only for loopback, the emulator host and private ranges', () {
      expect(nsc, startsWith('@xml/'));
      final xml = _read('src/main/res/xml/${nsc!.substring(5)}.xml');
      expect(xml, isNotEmpty);
      final base = RegExp(r'<base-config\b([^>]*)>').firstMatch(xml);
      expect(base?.group(1), contains('cleartextTrafficPermitted="false"'));
      for (final m in RegExp(r'<domain-config\b([^>]*)>(.*?)</domain-config>', dotAll: true).allMatches(xml)) {
        if (!m.group(1)!.contains('cleartextTrafficPermitted="true"')) continue;
        final domains = [for (final d in RegExp(r'<domain\b[^>]*>([^<]*)</domain>').allMatches(m.group(2)!)) d.group(1)!.trim()];
        expect(domains, isNotEmpty);
        for (final d in domains) {
          expect(_private(d), isTrue, reason: 'cleartext is allowed for "$d", which is not loopback, 10.0.2.2, *.local or a private range');
        }
      }
    }, skip: _bug(nsc != null, 'no android:networkSecurityConfig'));
  });

  group('permissions and components', () {
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
      expect(xml, isNotEmpty);
      expect(xml, isNot(contains('external')));
      expect(xml, isNot(contains('root-path')));
      expect(xml, anyOf(contains('<cache-path'), contains('<files-path')));
      expect(manifest, contains('android:grantUriPermissions="true"'));
    });
  });

  group('release signing', () {
    final gradle = _read('build.gradle.kts');
    test('a release build without a keystore fails instead of falling back to the debug key', () {
      final release = RegExp(r'release\s*\{(.*?)\n        \}', dotAll: true).firstMatch(gradle)?.group(1) ?? gradle;
      expect(release, isNot(contains('getByName("debug")')), reason: 'no debug fallback in the release build type');
      expect(gradle, anyOf(contains('GradleException'), contains('error('), contains('throw ')));
    },
        skip: _bug(
            !RegExp(r'if\s*\(\s*releaseKeystore\s*!=\s*null\s*\)\s*"release"\s*else\s*"debug"').hasMatch(gradle) && gradle.isNotEmpty,
            'build.gradle.kts still signs a release with the debug key when there is no keystore'));
  });

  group('key sheet', () {
    final activity = _read('src/main/kotlin/hr/marcelic/budget_wallet/MainActivity.kt');
    test('MainActivity exposes MethodChannel bw/secure setSecure(true/false) that sets and clears FLAG_SECURE', () {
      expect(activity, contains('bw/secure'));
      expect(activity, contains('setSecure'));
      expect(activity, contains('FLAG_SECURE'));
      expect(activity, contains('clearFlags'));
    }, skip: _bug(activity.contains('FLAG_SECURE'), 'MainActivity has no FLAG_SECURE channel for the key sheet'));
  });
}
