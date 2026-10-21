// Sync types the app reads (compile for the web). The folder transport itself (`FolderSync`, dart:io) is in
// `folder_sync_io.dart`, with a web stub in `folder_sync_web.dart`.
import 'sync_problems.dart';

export 'sync_problems.dart' show SyncProblem, SyncProblemReason, syncReaderVersion;

class SyncException implements Exception {
  final String message;
  const SyncException(this.message);
  @override
  String toString() => message;
}

class SyncReport {
  final int sent, received, filesRead;

  /// Files from other devices that were not applied: refused in this run, or refused earlier and unchanged since
  /// (those are not read again; a repaired copy, or for a newer format an app update, applies on a later run).
  final List<SyncProblem> problems;
  const SyncReport(this.sent, this.received, this.filesRead, {this.problems = const []});

  /// How many files were not applied ([problems]).
  int get badFiles => problems.length;

  /// Files not applied, per other device id.
  Map<String, int> get problemsByDevice {
    final out = <String, int>{};
    for (final p in problems) {
      out[p.device] = (out[p.device] ?? 0) + 1;
    }
    return out;
  }
}
