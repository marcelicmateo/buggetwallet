import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../logging.dart';
import '../platform.dart';
import '../theme.dart';
import '../widgets/async_action.dart';
import '../widgets/common.dart';

final _log = Logger('bw.app');

String _size(int bytes) =>
    bytes < 1024 ? '$bytes B' : (bytes < 1024 * 1024 ? '${(bytes / 1024).round()} KB' : '${(bytes / 1048576).toStringAsFixed(1)} MB');

/// Plan › Diagnostics: log level, log size, save and clear.
class DiagnosticsPanel extends StatefulWidget {
  final WalletController wc;
  final FileChooser chooser;
  const DiagnosticsPanel({super.key, required this.wc, this.chooser = const FileChooser()});
  @override
  State<DiagnosticsPanel> createState() => _DiagnosticsPanelState();
}

class _DiagnosticsPanelState extends State<DiagnosticsPanel> with AsyncAction {
  LogStats? stats;
  String? status;

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
    setState(() => status = null);
    final msg = await run(() async {
      try {
        return await body();
      } catch (e, st) {
        logError(_log, 'log.$what.failed', e, st);
        return "Couldn't do that: $e";
      }
    });
    if (!mounted) return;
    setState(() => status = msg);
    await _refresh();
  }

  /// The system save dialog (a download in a browser).
  Future<String?> _save() async {
    final wc = widget.wc;
    logNav('log.save');
    final bytes = await wc.logBytes();
    try {
      final uri = await widget.chooser.saveText(fileName: wc.logFileName(), bytes: bytes, title: 'Save logs');
      logEvent(_log, Level.INFO, 'log.saveDialog', {'saved': uri != null, 'bytes': bytes.length});
      return uri == null ? null : (isWeb ? 'Logs downloaded.' : 'Logs saved.');
    } catch (e, st) {
      logError(_log, 'log.saveDialogFailed', e, st, fields: {'type': e.runtimeType.toString()}, level: Level.INFO);
      return isWeb ? "Couldn't download the logs." : "Couldn't save the logs.";
    }
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final s = stats;
    return Panel(children: [
      const SectionHead('Diagnostics'),
      const Heading('Logs', size: BwType.headingSize),
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
      if (s != null && s.writeErrors > 0) LineItem('Log write errors', '${s.writeErrors} (logs may be incomplete)'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(
            key: const ValueKey('logsSave'),
            style: accentOutlined(context),
            onPressed: busy ? null : () => _run('save', _save),
            child: const Text('Save logs…')),
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
