import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../format.dart';
import '../logging.dart';
import '../storage_access.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'diagnostics.dart';

final _log = Logger('bw.app');

class PlanScreen extends StatefulWidget {
  final WalletController wc;
  const PlanScreen({super.key, required this.wc});
  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  static const _moneyKeys = {'salary', 'rent', 'loan', 'subs', 'impulse', 'rentCashThreshold'};
  static const _keys = ['salary', 'rent', 'loan', 'subs', 'impulse', 'coolHours', 'paydayDay', 'rentCashThreshold'];
  final Map<String, TextEditingController> f = {for (final k in _keys) k: TextEditingController()};

  /// The text each field last got from the settings. A field whose text differs was edited by the user:
  /// only those are saved, and only the others follow setting changes (sync, other screens).
  final Map<String, String> _shown = {};
  String currency = 'EUR';
  String _shownCurrency = 'EUR';
  bool importing = false;

  /// Field errors from the last Save, by key (shown under the field until it is edited).
  final Map<String, String> _errors = {};

  static String _plain(int cents) => cents % 100 == 0 ? '${cents ~/ 100}' : (cents / 100).toStringAsFixed(2);

  static String _text(WalletSettings s, String k) {
    final v = s.toMap()[k] as int;
    return _moneyKeys.contains(k) ? _plain(v) : '$v';
  }

  @override
  void initState() {
    super.initState();
    _fill(widget.wc.settings, force: true);
    widget.wc.addListener(_onChange);
  }

  @override
  void didUpdateWidget(PlanScreen old) {
    super.didUpdateWidget(old);
    if (old.wc != widget.wc) {
      old.wc.removeListener(_onChange);
      widget.wc.addListener(_onChange);
      _fill(widget.wc.settings, force: true);
    }
  }

  @override
  void dispose() {
    widget.wc.removeListener(_onChange);
    for (final c in f.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() => _fill(widget.wc.settings));
  }

  /// Shows [s] in every field the user has not edited ([force]: in every field).
  void _fill(WalletSettings s, {bool force = false}) {
    for (final k in _keys) {
      final t = _text(s, k), c = f[k]!;
      if ((force || c.text.trim() == _shown[k]) && c.text != t) c.text = t;
      _shown[k] = t;
    }
    if (force || currency == _shownCurrency) currency = s.currency;
    _shownCurrency = s.currency;
  }

  @override
  Widget build(BuildContext context) {
    final wc = widget.wc;
    final s = wc.settings;
    final cur = wc.currency;
    final p = wc.period();
    final lowIncome = p.received > 0 && p.received < s.salary * 0.9 && daysBetween(p.start, wc.today()) >= 4;

    Widget field(String key, String label, {bool money = true}) => TextField(
          controller: f[key],
          keyboardType: TextInputType.numberWithOptions(decimal: money),
          onChanged: (_) {
            if (_errors.containsKey(key)) setState(() => _errors.remove(key));
          },
          decoration: InputDecoration(
              labelText: label, suffixText: money ? currencySymbol(currency) : null, errorText: _errors[key], errorMaxLines: 3),
        );

    return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: gapped([
          Panel(children: [
            const Eyebrow('Payday plan'),
            Heading('${money(p.flexBudget, cur, decimals: 0)} to spend · ${money(p.planDaily, cur, decimals: 0)}/day'),
            const Muted('Salary minus bills minus savings. Whatever is left is your spending money until the next payday.'),
            Rows(children: [
              LineItem(
                  'Salary ${s.incomeMode == 'received' && p.received > 0 ? '(received)' : '(planned)'}', money(p.income, cur, decimals: 0)),
              LineItem('Rent', money(-s.rent, cur, decimals: 0),
                  sub: 'Paid since payday: ${money(p.fixedPaid['Rent'] ?? 0, cur, decimals: 0)}'),
              LineItem('Loan', money(-s.loan, cur, decimals: 0),
                  sub:
                      'Paid since payday: ${money(p.fixedPaid['Loan'] ?? 0, cur, decimals: 0)}${s.loanEnd != null ? ' · ends ${monthLong(s.loanEnd!)}' : ''}'),
              LineItem('Bills & subscriptions', money(-s.subs, cur, decimals: 0),
                  sub: 'Paid since payday: ${money(p.fixedPaid['Bills & subscriptions'] ?? 0, cur, decimals: 0)}'),
              for (final g in wc.goals) LineItem(g.name, money(-g.monthly, cur, decimals: 0), sub: 'savings goal'),
              LineItem('Spending money', money(p.flexBudget, cur, decimals: 0),
                  bold: true, sub: '${p.length} days, ${shortDate(p.start)} to ${shortDate(addDays(p.end, -1))}'),
            ]),
            if (lowIncome)
              Panel(color: context.c.warnBg, children: [
                Text(
                    'Salary received so far is ${money(p.received, cur, decimals: 0)}, below your planned ${money(s.salary, cur, decimals: 0)}.',
                    style: TextStyle(color: context.c.warnInk)),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: 'planned', label: Text('Plan on ${money(s.salary, cur, decimals: 0)}')),
                    ButtonSegment(value: 'received', label: Text('Plan on ${money(p.received, cur, decimals: 0)}')),
                  ],
                  selected: {s.incomeMode},
                  onSelectionChanged: (v) => wc.updateSettings({'incomeMode': v.first}),
                ),
              ]),
          ]),
          Panel(children: [
            const Heading('Numbers', size: 15),
            Row(children: [
              Expanded(child: field('salary', 'Salary per month')),
              const SizedBox(width: 10),
              Expanded(child: field('rent', 'Rent'))
            ]),
            Row(children: [
              Expanded(child: field('loan', 'Loan')),
              const SizedBox(width: 10),
              Expanded(child: field('subs', 'Bills & subs'))
            ]),
            Row(children: [
              Expanded(child: field('impulse', 'Wishlist above')),
              const SizedBox(width: 10),
              Expanded(child: field('coolHours', 'Wait (hours)', money: false))
            ]),
            Row(children: [
              Expanded(child: field('paydayDay', 'Latest payday', money: false)),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey(currency),
                  isExpanded: true,
                  initialValue: currency,
                  decoration: const InputDecoration(labelText: 'Currency'),
                  items: [
                    for (final c in const ['EUR', 'USD', 'GBP', 'CHF']) DropdownMenuItem(value: c, child: Text(c))
                  ],
                  onChanged: (v) => setState(() => currency = v ?? currency),
                ),
              ),
            ]),
            field('rentCashThreshold', 'Cash withdrawal counts as rent from'),
            const Muted('ATM withdrawals this big or bigger count as rent. 0 turns it off.', size: 12),
            FilledButton(onPressed: _savePlan, child: const Text('Save numbers')),
          ]),
          Panel(children: [
            const Heading('Month', size: 15),
            Muted(
                'Your month runs from the day your salary lands. Started ${shortDate(p.start)}; next payday expected by ${shortDate(p.end)}.'),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_repeat),
              label: const Text('Salary landed: start new month'),
              onPressed: () async {
                logNav('month.pick');
                final d = await showDatePicker(
                    context: context, initialDate: DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime.now());
                if (d == null) return;
                wc.startNewMonth(isoDate(d));
                if (context.mounted) toast(context, 'New month started ${shortDate(isoDate(d))}');
              },
            ),
          ]),
          Panel(children: [
            const Eyebrow('Weekly review'),
            const Heading('Import bank exports', size: 15),
            const Muted(
                'PBZ: Excel export of the current account. Revolut: account statement as Excel or CSV. Importing the same dates twice is safe; nothing gets doubled. Expenses you added by hand are matched to the bank rows.'),
            FilledButton.tonalIcon(
              icon: importing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.upload_file),
              label: const Text('Choose files'),
              onPressed: importing ? null : _import,
            ),
            for (final l in wc.lastImport) StatusLabel(good: l.ok, text: '${l.file}: ${l.message}'),
          ]),
          _syncPanel(context),
          DiagnosticsPanel(wc: wc),
        ]));
  }

  /// Saves only the fields the user edited, on top of the latest settings, so changes made elsewhere
  /// (another screen, another device) are kept.
  void _savePlan() {
    final s = widget.wc.settings;
    final vals = <String, int?>{
      for (final k in _keys)
        if (f[k]!.text.trim() != _shown[k]) k: _moneyKeys.contains(k) ? parseMoney(f[k]!.text) : int.tryParse(f[k]!.text.trim()),
    };
    // parseMoney already rejects negative amounts; whole-number fields can't be negative either.
    final errors = <String, String>{
      for (final e in vals.entries)
        if (e.value == null) e.key: 'Numbers only' else if (e.value! < 0) e.key: "Can't be negative",
    };
    if (errors.isNotEmpty) {
      logNav('plan.invalid', {'keys': errors.keys.join(',')}); // keys only
      setState(() => _errors
        ..clear()
        ..addAll(errors));
      toast(
          context,
          errors.containsKey('coolHours') && errors['coolHours'] != 'Numbers only'
              ? "Wait (hours) can't be negative."
              : 'Enter numbers only, like 1500 or 1500.50.');
      return;
    }
    if (_errors.isNotEmpty) setState(_errors.clear);
    final changes = <String, Object?>{...vals};
    if (changes['paydayDay'] case final int d) changes['paydayDay'] = d.clamp(1, 28);
    if (currency != s.currency) changes['currency'] = currency;
    final now = s.toMap();
    changes.removeWhere((k, v) => now[k] == v);
    if (changes.containsKey('salary')) changes['salaryConfirmed'] = true;
    // Edited fields show the saved value (e.g. "1500.0" -> "1500", payday 31 -> 28) and are no longer "edited".
    for (final k in vals.keys) {
      final t = _text(WalletSettings.fromMap({...now, ...changes}), k);
      f[k]!.text = t;
      _shown[k] = t;
    }
    if (changes.isEmpty) {
      toast(context, 'Nothing to save');
      return;
    }
    widget.wc.updateSettings(changes);
    toast(context, 'Plan saved');
  }

  Future<void> _import() async {
    logNav('import.pick');
    final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['xls', 'xlsx', 'csv']);
    if (picked.isEmpty) {
      logNav('import.cancelled');
      return;
    }
    setState(() => importing = true);
    final files = <(String, Uint8List)>[];
    try {
      for (final pf in picked) {
        files.add((pf.name, await pf.readAsBytes()));
      }
    } catch (e, st) {
      // describeError drops the path (it would name the bank file).
      logError(_log, 'import.openFailed', e, st, fields: {'files': picked.length, 'read': files.length});
      if (mounted) {
        setState(() => importing = false);
        toast(context, "Couldn't open that file.");
      }
      return;
    }
    // Extensions and sizes only, never file names.
    logNav('import.chosen', {
      'files': files.length,
      'exts': [for (final (n, _) in files) fileExt(n)],
      'bytes': [for (final (_, b) in files) b.length],
    });
    await widget.wc.importFiles(files);
    if (mounted) setState(() => importing = false);
  }

  Widget _syncPanel(BuildContext context) {
    final wc = widget.wc;
    final folder = wc.syncFolder;
    final last = wc.lastSync;
    return Panel(children: [
      const Eyebrow('Sync'),
      const Heading('Your devices', size: 15),
      const Muted(
          'Changes are encrypted on this device and written to a folder that Syncthing keeps in step across your phone and computer. Only devices with your wallet key can read them.'),
      LineItem('Sync folder', '', sub: folder ?? 'Not set'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (Platform.isIOS)
          OutlinedButton(
              onPressed: () async {
                logNav('sync.useAppFolder');
                await wc.setSyncFolder(await wc.defaultSyncFolder());
              },
              child: const Text('Use the app folder'))
        else
          OutlinedButton(
            onPressed: () async {
              logNav('sync.chooseFolder');
              final path = await FilePicker.getDirectoryPath(dialogTitle: 'Choose your Syncthing folder');
              logNav('sync.chooseFolder.done', {'picked': path != null}); // never the path
              if (path != null) await wc.setSyncFolder(path);
            },
            child: const Text('Choose folder'),
          ),
        if (!Platform.isIOS) OutlinedButton(onPressed: () => _typePath(context), child: const Text('Type path')),
        if (Platform.isAndroid)
          OutlinedButton(
            onPressed: () async {
              logNav('storage.pressed');
              if (await StorageAccess.granted()) {
                if (context.mounted) toast(context, 'File access is already allowed');
                return;
              }
              await StorageAccess.request();
            },
            child: const Text('Allow file access'),
          ),
        FilledButton.tonal(
            onPressed: folder == null || wc.syncing
                ? null
                : () {
                    logNav('sync.pressed');
                    wc.syncNow();
                  },
            child: Text(wc.syncing ? 'Syncing…' : 'Sync now')),
      ]),
      if (wc.syncError != null) StatusLabel(good: false, text: wc.syncError!),
      if (wc.syncError == null && last != null)
        StatusLabel(good: true, text: 'Synced at ${last.hour.toString().padLeft(2, '0')}:${last.minute.toString().padLeft(2, '0')}'),
      if (wc.syncError == null && wc.syncBadFiles > 0)
        StatusLabel(
            good: false,
            text: wc.syncBadFiles == 1
                ? '1 sync file could not be read. It was skipped and will be tried again.'
                : '${wc.syncBadFiles} sync files could not be read. They were skipped and will be tried again.'),
      OutlinedButton.icon(icon: const Icon(Icons.key), label: const Text('Show wallet key'), onPressed: () => _showKey(context)),
      Muted(Platform.isIOS
          ? 'On iPhone, sync the app folder (Files › On My iPhone › Budget Wallet › BudgetWalletSync) with the Möbius Sync app.'
          : 'Install Syncthing on each device and share one folder between them. Pick that folder here on every device.'),
    ]);
  }

  Future<void> _typePath(BuildContext context) async {
    final ctl =
        TextEditingController(text: widget.wc.syncFolder ?? (Platform.isAndroid ? '/storage/emulated/0/Documents/BudgetWallet' : ''));
    logNav('dialog.open', {'dialog': 'syncPath'});
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sync folder path'),
        content: TextField(controller: ctl, decoration: const InputDecoration(hintText: '/path/to/BudgetWallet')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Use folder')),
        ],
      ),
    );
    logNav('dialog.close', {'dialog': 'syncPath', 'set': path != null && path.isNotEmpty}); // never the path
    if (path == null || path.isEmpty) return;
    try {
      await Directory(path).create(recursive: true);
    } catch (e, st) {
      // Sync then reports the missing folder; describeError drops the path.
      logError(_log, 'sync.folderCreateFailed', e, st);
    }
    await widget.wc.setSyncFolder(path);
  }

  Future<void> _showKey(BuildContext context) async {
    logNav('dialog.open', {'dialog': 'walletKey'}); // the key itself is never logged
    final text = await widget.wc.keyText();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wallet key'),
        content: SizedBox(
          width: 320,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Anyone with this key can read your wallet. Use it only to add your own devices.', style: TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            Container(color: Colors.white, padding: const EdgeInsets.all(8), child: QrImageView(data: text, size: 200)),
            const SizedBox(height: 12),
            SelectableText(text, textAlign: TextAlign.center, style: numStyle.copyWith(fontSize: 13)),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              logNav('key.copied');
              await Clipboard.setData(ClipboardData(text: text));
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) toast(context, 'Key copied');
            },
            child: const Text('Copy'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
        ],
      ),
    );
  }
}
