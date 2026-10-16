import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../logging.dart';
import '../widgets/common.dart';

final _log = Logger('bw.app');

String _size(int bytes) =>
    bytes < 1024 ? '$bytes B' : (bytes < 1024 * 1024 ? '${(bytes / 1024).round()} KB' : '${(bytes / 1048576).toStringAsFixed(1)} MB');

/// Plan › Diagnostics: log level, log size, save and clear.
class DiagnosticsPanel extends StatefulWidget {
  final WalletController wc;
  const DiagnosticsPanel({super.key, required this.wc});
  @override
  State<DiagnosticsPanel> createState() => _DiagnosticsPanelState();
}

class _DiagnosticsPanelState extends State<DiagnosticsPanel> {
  LogStats? stats;
  String? status;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final s = await widget.wc.logStats();
      if (mounted) setState(() => stats = s);
    } catch (e, st) {
      logError(_log, 'log.statsFailed', e, st);
    }
  }

  Future<void> _run(String what, Future<String?> Function() body) async {
    setState(() {
      busy = true;
      status = null;
    });
    String? msg;
    try {
      msg = await body();
    } catch (e, st) {
      logError(_log, 'log.$what.failed', e, st);
      msg = "Couldn't do that: $e";
    }
    if (!mounted) return;
    setState(() {
      busy = false;
      status = msg;
    });
    await _refresh();
  }

  /// The system save dialog; where there is none (or it fails), the sync folder's diagnostics/ or app documents.
  Future<String?> _save() async {
    final wc = widget.wc;
    logNav('log.save');
    final bytes = await wc.logBytes();
    try {
      final uri = await FilePicker.saveFile(fileName: wc.logFileName(), bytes: bytes, mimeType: 'text/plain', dialogTitle: 'Save logs');
      logEvent(_log, Level.INFO, 'log.saveDialog', {'saved': uri != null, 'bytes': bytes.length});
      return uri == null ? null : 'Logs saved.';
    } catch (e, st) {
      logError(_log, 'log.saveDialogFailed', e, st, level: Level.INFO);
      return 'Saved to ${await wc.saveLogsToFolder()}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final s = stats;
    return Panel(children: [
      const Eyebrow('Diagnostics'),
      const Heading('Logs', size: 15),
      const Muted(
          'Logs help find bugs and slow spots. Debug logs everything (the default while testing). They never contain amounts, names, notes or your key.'),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'all', label: Text('Debug')),
          ButtonSegment(value: 'info', label: Text('Info')),
          ButtonSegment(value: 'warning', label: Text('Warnings')),
        ],
        selected: {wc.logLevel},
        onSelectionChanged: (v) => wc.setLogLevel(v.first),
      ),
      LineItem('Log files', s == null ? '…' : '${s.files} · ${_size(s.bytes)}'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.tonal(onPressed: busy ? null : () => _run('save', _save), child: const Text('Save logs…')),
        if (wc.syncFolder != null)
          OutlinedButton(
            onPressed: busy
                ? null
                : () => _run('saveToSync', () async {
                      logNav('log.saveToSync');
                      return 'Saved to ${await wc.saveLogsToFolder()}';
                    }),
            child: const Text('Put in sync folder'),
          ),
        OutlinedButton(
          onPressed: busy
              ? null
              : () => _run('clear', () async {
                    logNav('log.clear');
                    await wc.clearLogs();
                    return 'Logs cleared.';
                  }),
          child: const Text('Clear logs'),
        ),
      ]),
      if (status != null) Muted(status!),
    ]);
  }
}
