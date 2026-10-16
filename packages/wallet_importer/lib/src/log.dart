import 'dart:convert';

import 'package:logging/logging.dart';

/// A structured line in the same shape as wallet_core's `logEvent`: `<event> {"json":"fields"}`.
/// (wallet_core depends on this package, so its helper can't be used here.)
/// Fields are counts, sizes, formats and timings only: never cell contents, amounts or file names.
void logImporter(Logger log, Level level, String event, Map<String, Object?> fields) {
  if (!log.isLoggable(level)) return;
  log.log(level, fields.isEmpty ? event : '$event ${jsonEncode(fields)}');
}
