// Platform checks that also work on the web (no dart:io): built on kIsWeb and defaultTargetPlatform.
// Tests set debugDefaultTargetPlatformOverride to try another platform (flutter test reports android by default).
import 'package:flutter/foundation.dart';

bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
bool get isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// A phone or tablet app (Android, iOS).
bool get isMobile => isAndroid || isIOS;

/// A computer app (Windows, Linux, macOS).
bool get isDesktop => !kIsWeb && !isMobile;

/// Where a keyboard is the usual input: shortcut hints in tooltips show only here.
bool get hasKeyboard => kIsWeb || isDesktop;
