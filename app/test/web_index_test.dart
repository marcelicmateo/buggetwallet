// The web page's Content Security Policy (app/web/index.html) is pinned here: changing it is a decision, not an accident.
// The browser enforcing it is covered by `make web` + `make web-shot` (see app/CLAUDE.md, Web build).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _csp = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self' https: http://127.0.0.1:* http://localhost:*; "
    "img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; font-src 'self'; worker-src 'self' blob:; object-src 'none'; "
    "base-uri 'self'";

void main() {
  test('index.html carries exactly one CSP meta tag with the agreed policy', () {
    final html = File('web/index.html').readAsStringSync();
    final tags = RegExp(r'<meta http-equiv="Content-Security-Policy" content="([^"]*)">').allMatches(html).toList();
    expect(tags, hasLength(1));
    expect(tags.single.group(1), _csp);
    expect('Content-Security-Policy'.allMatches(html).length, 1, reason: 'no second policy');
  });

  test('the page loads no script from another origin and the bootstrap serves the renderer from this origin', () {
    final html = File('web/index.html').readAsStringSync();
    expect(RegExp(r'<script[^>]+src="https?://').hasMatch(html), isFalse);
    expect(RegExp(r'<script(?![^>]*\bsrc=)[^>]*>').hasMatch(html), isFalse, reason: 'no inline script: script-src has no unsafe-inline');
    final boot = File('web/flutter_bootstrap.js').readAsStringSync();
    expect(boot, contains("canvasKitBaseUrl: 'canvaskit/'"));
  });
}
