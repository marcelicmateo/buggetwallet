// The Needs-you queue (ENG E7a, docs/context/ENG_UI_SPEC.md §3 and §5.6): every suggestion and open question in one list, in the order of
// [NeedsYouKind] (most urgent first). It only reads what the screens already read; an answer goes through the same controller call the old
// tile used (the screens decide which). A `part` of controller.dart so it can use the cache.
//
// Privacy: logs carry kinds and counts only, never a name, an amount or an id.
part of 'controller.dart';

/// What can ask for the owner, most urgent first (the queue is ordered by this).
enum NeedsYouKind {
  deviceStop,
  conflicts,
  newDevice,
  periodEnded,
  newPayday,
  keyBackup,
  wizard,
  salary,
  balance,
  billReview,
  plannedCategory,
  overdue,
  review,
  loanAsk,
  goalReady,
  loanEnded,
  planProposal,
  payeeRule,
  ruleSuggest,
  headsUp,
}

/// One card of the queue. [data] is the object the answer needs (a bill, a proposal, an ask...), [picks] extra choices (one per loan
/// or goal). Texts are worked out here when they need no screen helper; the screen writes the rest from [data].
class NeedsYouItem {
  final NeedsYouKind kind;

  /// Unique and stable: kind plus the thing it is about. The card keys are made from it.
  final String id;
  final String tag, title, why;

  /// Money in the card's corner, in the wallet currency's minor units (null = none).
  final int? cents;
  final String primary;
  final String? alt;
  final List<({String id, String label})> picks;
  final Object? data;
  const NeedsYouItem(this.kind, this.id,
      {required this.tag,
      required this.title,
      this.why = '',
      this.cents,
      required this.primary,
      this.alt,
      this.picks = const [],
      this.data});
}

/// The four steps of the weekly review as the queue shows them: 0 = to do, 1 = now, 2 = done.
typedef NeedsYouStep = ({String label, int state});

extension NeedsYou on WalletController {
  /// The whole queue, ordered by urgency. The parts that read the wallet are cached per data version; the ones that read device-local
  /// state (sync stop, key prompt, setup, dismissed suggestions) are read on each call, so a tap shows at once.
  List<NeedsYouItem> needsYouItems() {
    final key = (dataVersion, notifyCount, today());
    if (_needsKey != key || _needsVal == null) {
      _needsVal = List.unmodifiable(_buildNeedsYou());
      _needsKey = key;
    }
    return _needsVal!;
  }

  List<NeedsYouItem> _buildNeedsYou() {
    final items = [..._needsYouLive(), ..._cached(const MemoKey('needsYouData'), _needsYouData)];
    // List.sort is not stable: the index keeps the order the sources gave within one kind.
    final order = {for (var i = 0; i < items.length; i++) items[i]: i};
    items.sort((a, b) {
      final k = a.kind.index.compareTo(b.kind.index);
      return k != 0 ? k : order[a]!.compareTo(order[b]!);
    });
    return items;
  }

  /// A value that reads every payment (200 ms or more on a big wallet, too long for a frame). With the background work on, right after
  /// a data change the last value is returned instead of working the new one out in the frame that asks; the idle warm-up steps
  /// (`force`) work it out, then [warmNeedsYou] tells the screens. The first time, and with the background work off, it is worked out at once.
  T _heavy<T>(String name, T Function() compute, {bool force = false}) {
    final at = (dataVersion, today());
    if (!force && WarmUp.enabled && _heavyAt[name] != at && _heavyLast.containsKey(name)) {
      _heavyWanted = true;
      return _heavyLast[name] as T;
    }
    _heavyAt[name] = at;
    final v = compute();
    _heavyLast[name] = v;
    return v;
  }

  /// Idle warm-up step, after the heavy values are worked out: builds the queue again and tells the screens if they were given old values.
  void warmNeedsYou() {
    _needsKey = null;
    needsYouItems();
    if (_heavyWanted) {
      _heavyWanted = false;
      notifyListeners();
    }
  }

  /// How many cards the queue has: the number on the Overview badge.
  int needsYouCount() => needsYouItems().length;

  /// Device-local state and the sync stop.
  List<NeedsYouItem> _needsYouLive() {
    final s = settings, p = period();
    final out = <NeedsYouItem>[];
    if (deviceStop != null) {
      final pending = deviceStop == DeviceStop.pending;
      out.add(NeedsYouItem(NeedsYouKind.deviceStop, 'deviceStop',
          tag: 'This device',
          title: pending ? 'Waiting for approval' : 'Removed from the wallet',
          why: pending && deviceCode != null ? 'Code $deviceCode' : 'It has no access now.',
          primary: 'Open Sync',
          data: deviceStop));
    }
    final conflicts = syncConflictCount;
    if (conflicts > 0) {
      out.add(NeedsYouItem(NeedsYouKind.conflicts, 'conflicts',
          tag: 'Devices disagree',
          title: '$conflicts ${conflicts == 1 ? 'value differs' : 'values differ'} between your devices',
          why: 'Choose the right ones.',
          primary: 'Choose'));
    }
    for (final w in deviceList?.pending ?? const <PendingRow>[]) {
      out.add(NeedsYouItem(NeedsYouKind.newDevice, 'newDevice:${w.fp}',
          tag: 'New device',
          title: '${w.name} wants to join',
          why: 'Compare the code on its screen with the one in Sync before you approve.',
          primary: 'Open Sync',
          data: w));
    }
    final ended = HeroFigure.of(p).ended;
    final newPayday = this.newPayday(p.start);
    if (ended && newPayday == null) {
      final start = currentPeriodStart(p.start, s.paydayDay, today());
      out.add(NeedsYouItem(NeedsYouKind.periodEnded, 'periodEnded',
          tag: 'New pay period',
          title: 'Your pay period ended',
          why: 'Start the next one to get a new daily budget.',
          primary: 'Start new period on ${shortDateOrRaw(start)}',
          data: start));
    }
    if (newPayday != null) {
      out.add(NeedsYouItem(NeedsYouKind.newPayday, 'newPayday',
          tag: 'Salary landed',
          title: 'Salary landed on ${shortDateOrRaw(newPayday)}',
          why: 'Start a new month to reset your daily budget and run the payday checklist.',
          primary: 'Start new month on ${shortDateOrRaw(newPayday)}',
          data: newPayday));
    }
    if (keyBackupRowVisible) {
      out.add(const NeedsYouItem(NeedsYouKind.keyBackup, 'keyBackup',
          tag: 'Wallet key',
          title: 'Save your wallet key',
          why: 'Without it, this wallet cannot be opened again.',
          primary: 'Save now',
          alt: 'Later'));
    }
    if (setupWizardOpen) {
      out.add(NeedsYouItem(NeedsYouKind.wizard, 'wizard',
          tag: 'Set up',
          title: 'Finish setting up',
          why: 'Step $setupWizardStep of $setupWizardSteps. Every step can be skipped.',
          primary: 'Continue',
          alt: 'No thanks'));
    }
    if (!s.salaryConfirmed) {
      out.add(NeedsYouItem(NeedsYouKind.salary, 'salary',
          tag: 'Set up',
          title: s.salary > 0 ? 'Planning on a salary of' : 'Your salary is not set',
          why: s.salary > 0
              ? 'Check this matches a normal month of pay. Fix it in Plan if not.'
              : 'Enter your monthly salary in Plan so the daily budget can be worked out.',
          cents: s.salary > 0 ? s.salary : null,
          primary: 'Looks right',
          alt: 'Open Plan'));
    }
    for (final pr in planProposalList()) {
      out.add(NeedsYouItem(NeedsYouKind.planProposal, 'plan:${pr.key}',
          tag: 'Plan suggestion', title: pr.key, primary: 'Accept', alt: 'Not now', data: pr));
    }
    for (final pc in payeeRecommendations()) {
      out.add(NeedsYouItem(NeedsYouKind.payeeRule, 'payee:${pc.merchantKey}',
          tag: 'No main tag',
          title: pc.merchantName,
          why: '${pc.count} payments with no main tag. Make a rule?',
          primary: 'Make rule',
          alt: 'Dismiss',
          data: pc));
    }
    for (final r in ruleSuggestionList) {
      out.add(NeedsYouItem(NeedsYouKind.ruleSuggest, 'rule:${r.merchantKey}',
          tag: 'Rule suggestion',
          title: 'Always tag "${r.merchantName}" as ${categoryTable.label(r.category)}?',
          why: 'You chose it on ${r.count} payments.',
          primary: 'Accept',
          alt: 'Dismiss',
          data: r));
    }
    return out;
  }

  /// The parts that follow the wallet's data only.
  List<NeedsYouItem> _needsYouData() {
    final p = period(), cur = currency, todayDate = today();
    final out = <NeedsYouItem>[];
    for (final w in balanceWarningList()) {
      final (why, cents) = switch (w.kind) {
        BalanceWarningKind.belowNow => ('Below zero now.', w.cents),
        BalanceWarningKind.goesBelow => (
            'Goes below zero on ${shortDateOrRaw(w.date ?? '')}${(w.cause ?? '').isEmpty ? '' : ' (${w.cause})'}.',
            null
          ),
        BalanceWarningKind.checkBalance => ('The balance was not confirmed lately.', null),
      };
      out.add(NeedsYouItem(NeedsYouKind.balance, 'balance:${w.account.id}',
          tag: 'Account',
          title: w.account.name,
          why: why,
          cents: cents,
          primary: 'Check balance',
          alt: w.kind == BalanceWarningKind.checkBalance ? null : 'See coming up',
          data: w));
    }
    for (final b in billLists().review) {
      out.add(NeedsYouItem(NeedsYouKind.billReview, 'bill:${b.id}',
          tag: 'Bill to check',
          title: (b.payee ?? '').isNotEmpty
              ? b.payee!
              : (b.description ?? '').isNotEmpty
                  ? b.description!
                  : 'Bill',
          why: b.dueDate == null
              ? 'Check the amount and date before it holds money.'
              : 'Due ${shortDateOrRaw(b.dueDate!)}. Check it before it holds money.',
          cents: b.total,
          primary: 'Check bill',
          data: b));
    }
    for (final n in plannedNeedingCategory()) {
      out.add(NeedsYouItem(NeedsYouKind.plannedCategory, 'category:${n.id}',
          tag: 'Needs a category',
          title: n.title.isEmpty ? 'Bill' : n.title,
          why: 'It holds no money until it has a category.',
          cents: n.amount,
          primary: 'Open bill',
          data: n));
    }
    final overdue = {
      for (final x in p.dueCycles)
        if (x.due.compareTo(todayDate) < 0) x.bill.id
    }.length;
    if (overdue > 0) {
      out.add(NeedsYouItem(NeedsYouKind.overdue, 'overdue',
          tag: 'Bills',
          title: overdue == 1 ? '1 bill is overdue' : '$overdue bills are overdue',
          why: 'Past their date and not paid.',
          primary: 'Open bills'));
    }
    final review = this.reviewState();
    if (review.due) {
      out.add(const NeedsYouItem(NeedsYouKind.review, 'review', tag: 'Weekly review', title: 'Weekly review', primary: 'Start review'));
    }
    for (final a in repo.pendingLoanPayments()) {
      final names = [for (final l in a.loans) l.name];
      out.add(NeedsYouItem(NeedsYouKind.loanAsk, 'loanAsk:${a.payment.txId}',
          tag: 'Loan payment?',
          title: 'A payment on ${shortDateOrRaw(a.payment.date)} may pay ${names.join(' or ')}',
          why: 'Found by the lender\'s name or reference.',
          cents: a.payment.amount,
          primary: a.loans.length > 1 ? 'Yes, ${a.loans.first.name}' : 'Yes',
          alt: 'No',
          picks: [for (final l in a.loans.skip(1)) (id: l.id, label: 'Yes, ${l.name}')],
          data: a));
    }
    for (final g in goals) {
      if (g.price == null || !goalReady(g)) continue;
      out.add(NeedsYouItem(NeedsYouKind.goalReady, 'goal:${g.id}',
          tag: 'Goal ready',
          title: '${g.name} is ready to buy',
          why: 'You have put enough aside.',
          cents: goalTarget(g),
          primary: 'Open planner',
          data: g));
    }
    for (final e in loanEnded()) {
      final open = [
        for (final g in goals)
          if (g.boughtAt == null) g
      ];
      out.add(NeedsYouItem(NeedsYouKind.loanEnded, 'loanEnded:${e.loanId}',
          tag: 'Loan paid off',
          title: 'Your ${loanOf(e.loanId)?.name ?? 'loan'} loan has ended',
          why: 'Move ${moneyExact(e.payment, cur)} a month to savings or a goal?',
          cents: e.payment,
          primary: open.isEmpty ? 'Keep as spending money' : 'Add to ${open.first.name}',
          alt: open.isEmpty ? null : 'Keep as spending money',
          picks: [for (final g in open.skip(1)) (id: g.id, label: 'Add to ${g.name}')],
          data: (e, open.isEmpty ? null : open.first.id)));
    }
    for (final h in headsUpLines()) {
      // A bill that needs a category already has its own card.
      if (h.item.planned?.needsCategory ?? false) continue;
      out.add(NeedsYouItem(NeedsYouKind.headsUp, 'headsUp:${h.item.key}',
          tag: 'Coming up',
          title: h.item.title.isEmpty ? 'Planned cost' : h.item.title,
          why: h.daysLeft == 0
              ? 'Today'
              : h.daysLeft == 1
                  ? 'Tomorrow'
                  : 'In ${h.daysLeft} days',
          cents: h.item.amount,
          primary: 'Open',
          data: h));
    }
    return out;
  }

  /// The weekly review as four steps (import, decide, pace, done) while one is due; empty otherwise. The first step not done is "now".
  List<NeedsYouStep> needsYouReviewSteps(List<NeedsYouItem> queue) {
    final r = this.reviewState();
    if (!r.due) return const [];
    final done = [
      lastImport.any((l) => l.ok),
      !queue.any((i) => i.kind != NeedsYouKind.review && i.kind.index < NeedsYouKind.headsUp.index && i.kind != NeedsYouKind.salary),
      r.count('pace') == 0,
      false,
    ];
    const labels = ['Import', 'Decide', 'Pace', 'Done'];
    final now = done.indexOf(false);
    return [for (var i = 0; i < 4; i++) (label: labels[i], state: done[i] ? 2 : (i == now ? 1 : 0))];
  }

  // ---------- Undo for the answers that only hide a suggestion on this device ----------

  /// Takes back [dismissRuleSuggestion].
  void restoreRuleSuggestion(String key) => _restoreLocalKey('ruleSuggestOff', key);

  /// Takes back [dismissPayeeRecommendation].
  void restorePayeeRecommendation(String key) => _restoreLocalKey('payeeRecOff', key);

  void _restoreLocalKey(String name, String key) {
    final off = {..._localKeys(name)}..remove(key);
    repo.setLocalValue(name, off.isEmpty ? null : jsonEncode(off.toList()..sort()));
    logEvent(_suggestLog, Level.INFO, 'needsYou.restore', {'what': name});
    notifyListeners();
  }

  /// Takes back [putOffPlanProposal].
  void restorePlanProposal(String key) {
    repo.setLocalValue('planNotNow:$key', null);
    logEvent(_accLog, Level.INFO, 'needsYou.restore', {'what': 'planNotNow'});
    _refreshView();
  }

  /// Takes back [snoozeKeyBackup] (the prompt shows again).
  void unsnoozeKeyBackup() {
    repo.setLocalValue('keyBackupSnoozedUntil', null);
    _keyBackupChanged();
  }
}

extension NeedsYouUndo on WalletController {
  /// Takes back [declineSetupWizard]: the wizard state it had (null = none).
  void restoreSetupWizard(String? state) {
    repo.setLocalValue('setupWizard', state);
    _keyBackupChanged();
  }
}
