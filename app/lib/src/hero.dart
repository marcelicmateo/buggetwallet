import 'package:wallet_core/wallet_core.dart';

/// The one number under Today's heading and on the setup wizard's last step: what is left this pay period once it ended, how far over
/// today's money, else the safe amount. Never negative. One place, so the two screens cannot drift.
class HeroFigure {
  final int amount;
  final bool ended, over;
  const HeroFigure(this.amount, {required this.ended, required this.over});

  factory HeroFigure.of(PeriodBudget p) {
    final ended = p.paydayPassed, over = p.overToday > 0;
    return HeroFigure(ended ? (p.remaining > 0 ? p.remaining : 0) : (over ? p.overToday : p.safeToday), ended: ended, over: over);
  }

  String get label => ended ? 'Left this pay period' : (over ? 'Over today by' : 'Safe to spend today');

  /// Shown in the warning colour and to the cent when small.
  bool get worry => over && !ended;
}
