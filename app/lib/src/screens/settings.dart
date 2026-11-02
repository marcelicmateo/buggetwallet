import 'package:flutter/material.dart';

import '../controller.dart';
import '../file_chooser.dart';
import '../layout.dart';
import '../logging.dart';
import '../platform.dart';
import '../tabs.dart';
import '../theme.dart';
import '../widgets/jump_when_built.dart';
import '../widgets/rebuild_when_shown.dart';
import '../widgets/scroll_to.dart';
import 'accounts_panel.dart';
import 'backup_panel.dart';
import 'calendars_panel.dart';
import 'csv_layouts_panel.dart';
import 'currencies_panel.dart';
import 'diagnostics.dart';
import 'export_panel.dart';
import 'habits_panels.dart';
import 'key_backup.dart';
import 'look_panel.dart';
import 'settings_panels.dart';
import 'setup_wizard.dart';
import 'sync_panel.dart';

/// The panels of [section], unchanged from the Plan tab. The first one carries the section's key from [keys] (the one page scrolls to it).
List<Widget> settingsPanels(BuildContext context, WalletController wc, SettingsSection section,
    {FileChooser chooser = const FileChooser(), Map<SettingsSection, GlobalKey>? keys}) {
  Widget keyed(Widget w) => KeyedSubtree(key: keys?[section], child: w);
  return switch (section) {
    SettingsSection.accounts => [
        keyed(AccountsPanel(wc: wc)),
        KeyedSubtree(key: keys?[SettingsSection.currencies], child: CurrenciesPanel(wc: wc)),
      ],
    SettingsSection.import => [keyed(ImportPanel(wc: wc, chooser: chooser)), CsvLayoutsPanel(wc: wc, chooser: chooser)],
    SettingsSection.sync => [
        keyed(SyncPanel(wc: wc, onShowKey: () => showWalletKey(context, wc))),
        if (!isWeb) AnotherWalletPanel(wc: wc),
        if (isWeb) BrowserPanel(wc: wc),
      ],
    SettingsSection.backup => [keyed(BackupPanel(wc: wc, chooser: chooser)), ExportPanel(wc: wc, chooser: chooser)],
    SettingsSection.calendars => [
        keyed(CalendarsPanel(key: const ValueKey('calendarsPanel'), wc: wc, chooser: chooser)),
        if (!isWeb) NudgesPanel(wc: wc),
        ReviewDayPanel(wc: wc),
      ],
    SettingsSection.look => [keyed(LookPanel(wc: wc))],
    SettingsSection.diagnostics => [keyed(DiagnosticsPanel(wc: wc, chooser: chooser))],
    SettingsSection.currencies => const [],
  };
}

/// The Settings tab (P5): every section that used to be in Plan, apart from the payday plan (Budget) and the bills (Bills).
/// A phone and a narrow window show one page with all sections in order; from [twoColMin] wide the section list is on the
/// left and the chosen section on the right. A link ([WalletController.openSettings]) selects its section, or scrolls to it.
class SettingsScreen extends StatefulWidget {
  final WalletController wc;

  /// The system file and folder choosers (tests pass one that fails).
  final FileChooser chooser;
  const SettingsScreen({super.key, required this.wc, this.chooser = const FileChooser()});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingsSection selected = SettingsSection.accounts;
  bool _twoPane = false;
  final _scroll = ScrollController();
  final Map<SettingsSection, GlobalKey> _keys = {for (final s in SettingsSection.values) s: GlobalKey()};

  @override
  void initState() {
    super.initState();
    widget.wc.settingsRequest.addListener(_jump);
    jumpWhenBuilt(widget.wc.settingsRequest, () => mounted, _jump); // a link that opened this tab before its page existed
  }

  @override
  void didUpdateWidget(SettingsScreen old) {
    super.didUpdateWidget(old);
    if (old.wc != widget.wc) {
      old.wc.settingsRequest.removeListener(_jump);
      widget.wc.settingsRequest.addListener(_jump);
    }
  }

  @override
  void dispose() {
    widget.wc.settingsRequest.removeListener(_jump);
    _scroll.dispose();
    super.dispose();
  }

  /// A link: two panes select the section (and scroll to a place inside it); one page scrolls to it.
  void _jump() {
    final s = widget.wc.settingsRequest.value;
    if (s == null || !mounted) return;
    if (_twoPane) {
      setState(() => selected = s.nav);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_scroll.hasClients) _scroll.jumpTo(0);
        if (s != s.nav) scrollToKey(_scroll, _keys[s]!, alive: () => mounted);
      });
    } else {
      scrollToKey(_scroll, _keys[s]!, alive: () => mounted);
    }
  }

  void _select(SettingsSection s) {
    logNav('settings.section', {'section': s.name});
    setState(() => selected = s);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  List<Widget> _panels(SettingsSection s) => settingsPanels(context, widget.wc, s, chooser: widget.chooser, keys: _keys);

  // The panels read the wallet in build(); the old Plan tab rebuilt on every change of the controller (a device-local switch changes
  // no data version, so the shell would not rebuild the page), and so does this one while it is shown.
  @override
  Widget build(BuildContext context) => RebuildWhenShown(
      listenable: widget.wc,
      builder: (context) => LayoutBuilder(builder: (context, box) {
            _twoPane = box.maxWidth >= twoColMin;
            return _twoPane ? _twoPanes(context) : _onePage(context);
          }));

  Widget _onePage(BuildContext context) => NarrowPage(
        child: ListView(
          key: const ValueKey('settingsPage'),
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
          children: gapped([_SetupAgainRow(wc: widget.wc, chooser: widget.chooser), for (final s in SettingsSection.listed) ..._panels(s)]),
        ),
      );

  Widget _twoPanes(BuildContext context) => MarginLine(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 300,
            // A plain column in a scroll view: all twelve rows are built (a short window just scrolls).
            child: SingleChildScrollView(
              key: const ValueKey('settingsList'),
              padding: const EdgeInsets.fromLTRB(pagePad, 8, 8, pageBottomPad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final s in SettingsSection.listed) _NavRow(s, selected: s == selected, onTap: () => _select(s)),
                  _SetupAgainRow(wc: widget.wc, chooser: widget.chooser),
                ],
              ),
            ),
          ),
          ColoredBox(color: context.c.line, child: const SizedBox(width: 1)),
          Expanded(
            child: ListView(
              key: const ValueKey('settingsPane'),
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(pagePad, 8, pagePad, pageBottomPad),
              children: gapped(_panels(selected)),
            ),
          ),
        ]),
      );
}

/// "Set up my wallet again": opens the setup wizard from step 1 with the wallet's current values (not a section).
class _SetupAgainRow extends StatelessWidget {
  final WalletController wc;
  final FileChooser chooser;
  const _SetupAgainRow({required this.wc, required this.chooser});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      key: const ValueKey('setupAgain'),
      onTap: () => openSetupWizard(context, wc, chooser: chooser, restart: true),
      hoverColor: c.surface2,
      focusColor: c.accentSoft,
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.line))),
        child: Row(children: [
          Icon(Icons.auto_fix_high, size: 18, color: c.ink),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Set up my wallet again', style: TextStyle(fontWeight: FontWeight.w500)),
              Text('Files, accounts, plan, bills, tags, budgets', style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
            ]),
          ),
          Icon(Icons.chevron_right, size: 20, color: c.ink2),
        ]),
      ),
    );
  }
}

/// One entry of the section list: title and a one-line sub; the chosen one is tinted, bold and has an arrow.
class _NavRow extends StatelessWidget {
  final SettingsSection section;
  final bool selected;
  final VoidCallback onTap;
  const _NavRow(this.section, {required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        key: ValueKey('settingsNav:${section.name}'),
        onTap: onTap,
        hoverColor: c.surface2,
        focusColor: c.accentSoft,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? c.accentSoft : null,
            border: Border(left: BorderSide(color: selected ? c.ink : Colors.transparent, width: 3), bottom: BorderSide(color: c.line)),
          ),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(section.title, style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
                Text(section.sub, style: TextStyle(fontSize: BwType.metaSize, color: c.ink2)),
              ]),
            ),
            if (selected) Icon(Icons.chevron_right, size: 20, color: c.ink),
          ]),
        ),
      ),
    );
  }
}
