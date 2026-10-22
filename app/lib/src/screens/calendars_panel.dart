import 'package:file_picker/file_picker.dart' show PlatformFile;
import 'package:flutter/material.dart';
import 'package:wallet_core/wallet_core.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../format.dart';
import '../logging.dart';
import '../theme.dart';
import '../widgets/common.dart';

final _log = Logger('bw.calendar');

/// Plan › Calendars: which calendars feed Upcoming, and when to warn about a big cost.
/// Android: the phone's calendars (any account that syncs to the phone) after the system permission. Everywhere: import an
/// `.ics` file; apps (not the browser) can also add an `.ics` link, refreshed at start and resume. Read only: nothing is ever
/// written to a calendar. Files, links and what was read stay on this device and are never put in the logs.
class CalendarsPanel extends StatefulWidget {
  final WalletController wc;
  final FileChooser chooser;
  const CalendarsPanel({super.key, required this.wc, this.chooser = const FileChooser()});
  @override
  State<CalendarsPanel> createState() => _CalendarsPanelState();
}

class _CalendarsPanelState extends State<CalendarsPanel> {
  final _link = TextEditingController();
  late final _cents = TextEditingController(text: _plain(widget.wc.headsUpCents));
  late final _days = TextEditingController(text: '${widget.wc.headsUpDays}');
  bool _addingLink = false, _busy = false;
  String? _error, _headsUpError;

  static String _plain(int cents) => cents % 100 == 0 ? '${cents ~/ 100}' : (cents / 100).toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    widget.wc.checkCalendarAccess();
  }

  @override
  void dispose() {
    _link.dispose();
    _cents.dispose();
    _days.dispose();
    super.dispose();
  }

  Future<void> _allow() async {
    logNav('calendar.allow');
    await widget.wc.requestCalendarAccess();
    if (mounted && widget.wc.cal.permission) toast(context, 'Calendars found. Switch on the ones to read.');
  }

  Future<void> _importFile() async {
    logNav('calendar.import');
    final List<PlatformFile> picked;
    try {
      picked = await widget.chooser.pickCalendarFile();
    } catch (e, st) {
      logError(_log, 'calendar.pickerFailed', e, st, fields: {'type': e.runtimeType.toString()});
      if (mounted) setState(() => _error = chooserFailedMessage);
      return;
    }
    if (picked.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final bytes = await picked.first.readAsBytes();
      final err = await widget.wc.importIcsFile(picked.first.name, bytes);
      if (!mounted) return;
      setState(() => _error = err);
      if (err == null) toast(context, 'Calendar added');
    } catch (e, st) {
      logError(_log, 'calendar.openFailed', e, st, fields: {'type': e.runtimeType.toString()});
      if (mounted) setState(() => _error = "Couldn't open that file.");
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addLink() async {
    logNav('calendar.link');
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await widget.wc.addIcsLink(_link.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
      if (err == null) {
        _link.clear();
        _addingLink = false;
      }
    });
    if (err == null) toast(context, 'Calendar added');
  }

  Future<void> _readNow() async {
    logNav('calendar.read');
    setState(() => _busy = true);
    await widget.wc.readCalendars(trigger: 'button');
    if (mounted) setState(() => _busy = false);
  }

  void _saveHeadsUp() {
    final cents = parseMoney(_cents.text);
    final days = int.tryParse(_days.text.trim());
    if (cents == null || cents > 10000000) {
      setState(() => _headsUpError = 'Enter an amount, like 100. Use 0 to hear about every cost.');
      return;
    }
    if (days == null || days < 0 || days > 14) {
      setState(() => _headsUpError = 'Days must be from 0 to 14.');
      return;
    }
    widget.wc.saveHeadsUp(cents: cents, days: days);
    setState(() => _headsUpError = null);
    toast(context, 'Saved');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.wc,
      builder: (context, _) {
        final wc = widget.wc;
        final c = context.c;
        final entries = wc.calendarEntries();
        final device = entries.where((e) => e.kind == CalendarKind.device).toList();
        final imported = entries.where((e) => e.kind != CalendarKind.device).toList();
        final reads = device.any((e) => e.on) || imported.isNotEmpty;
        return Panel(children: [
          const SectionHead('Calendars'),
          const Muted(
              'Events with a cost show up in Upcoming as suggestions. Nothing counts until you confirm an amount. The app only reads; it never changes a calendar. Stays on this device.'),
          if (wc.deviceCalendarsSupported) ...[
            const Heading('This phone', size: 15),
            if (!wc.cal.permission)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                    key: const ValueKey('calAllow'),
                    style: accentOutlined(context),
                    icon: const Icon(Icons.event_available_outlined),
                    label: const Text('Allow calendar access'),
                    onPressed: _allow),
              ),
            if (wc.cal.denied && !wc.cal.permission)
              const StatusLabel(
                  good: false, text: 'Calendar access was refused. Allow it for Budget Wallet in the system settings, then try again.'),
            if (wc.cal.permission && device.isEmpty) const Muted('No calendars found on this phone.'),
            for (final e in device)
              SwitchListTile(
                key: ValueKey('cal:${e.id}'),
                contentPadding: EdgeInsets.zero,
                value: e.on,
                onChanged: (on) {
                  logNav('calendar.switch', {'on': on});
                  wc.setCalendarOn(e.id, on);
                },
                title: Text(e.name, style: const TextStyle(fontSize: 14.5)),
                subtitle: e.account == null ? null : Text(e.account!, style: TextStyle(fontSize: 12.5, color: c.ink2)),
              ),
          ],
          Heading(wc.deviceCalendarsSupported ? 'Files and links' : 'Calendar files', size: 15),
          if (imported.isEmpty) const Muted('No .ics calendars yet.'),
          for (final e in imported)
            Container(
              key: ValueKey('ics:${e.id}'),
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(children: [
                Icon(e.kind == CalendarKind.link ? Icons.link : Icons.insert_drive_file_outlined, size: 18, color: c.ink2),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(e.name, style: const TextStyle(fontWeight: FontWeight.w500)),
                    if (e.error != null) StatusLabel(good: false, text: e.error!),
                  ]),
                ),
                IconButton(
                  key: ValueKey('icsRemove:${e.id}'),
                  tooltip: 'Remove calendar',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    logNav('calendar.remove');
                    wc.removeCalendarSource(e.id);
                  },
                ),
              ]),
            ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
                key: const ValueKey('calImport'),
                icon: const Icon(Icons.upload_file),
                label: const Text('Import .ics file'),
                onPressed: _busy ? null : _importFile),
            if (wc.linksSupported)
              OutlinedButton.icon(
                  key: const ValueKey('calLink'),
                  icon: const Icon(Icons.add_link),
                  label: const Text('Add .ics link'),
                  onPressed: _busy ? null : () => setState(() => _addingLink = !_addingLink)),
            if (reads)
              OutlinedButton.icon(
                  key: const ValueKey('calRead'),
                  icon: _busy || wc.cal.reading
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.sync),
                  label: const Text('Read now'),
                  onPressed: _busy || wc.cal.reading ? null : _readNow),
          ]),
          if (_addingLink) ...[
            TextField(
              key: const ValueKey('calLinkField'),
              controller: _link,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Calendar link', hintText: 'https://…/calendar.ics'),
            ),
            Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(key: const ValueKey('calLinkAdd'), onPressed: _busy ? null : _addLink, child: const Text('Add link'))),
            const Muted('The link is kept on this device only and read again when the app starts.', size: 12.5),
          ],
          if (_error != null) StatusLabel(key: const ValueKey('calError'), good: false, text: _error!),
          if (reads && wc.cal.lastRead != null)
            Muted('Read ${wc.cal.events.length} ${wc.cal.events.length == 1 ? 'event' : 'events'} for the next 90 days.', size: 12.5),
          if (!wc.deviceCalendarsSupported && !wc.linksSupported)
            const Muted('In the browser you can import a .ics file. The phone app reads calendars directly.', size: 12.5),
          const Divider(height: 24),
          const Heading('Heads-up', size: 15),
          const Muted('Today and a notification warn you a few days before a planned cost this big or bigger.'),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                key: const ValueKey('headsUpCents'),
                controller: _cents,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                textAlign: TextAlign.end,
                style: numStyle,
                decoration: InputDecoration(labelText: 'From amount', suffixText: currencySymbol(wc.currency)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                key: const ValueKey('headsUpDays'),
                controller: _days,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.end,
                style: numStyle,
                decoration: const InputDecoration(labelText: 'Days before'),
              ),
            ),
          ]),
          if (_headsUpError != null) StatusLabel(key: const ValueKey('headsUpError'), good: false, text: _headsUpError!),
          Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(key: const ValueKey('headsUpSave'), onPressed: _saveHeadsUp, child: const Text('Save heads-up'))),
        ]);
      });
}
