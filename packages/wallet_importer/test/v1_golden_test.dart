// Golden vectors from the v1 web app (artifact/index.html, parseRows + makeIds), computed by running v1's own JS on
// the SYNTHETIC rows below. v2 must produce the same ids so re-imports never duplicate across v1 and v2.
import 'package:test/test.dart';
import 'package:wallet_importer/wallet_importer.dart';

/// [date, cents, description, v1 id]
typedef Golden = (String, int, String, String);

void main() {
  // Same rows as artifact/tests/core.test.js PBZ_ROWS, plus extra synthetic edge cases (triplicates, Croatian
  // letters, euro sign, comma decimals, d.m.yyyy dates, zero, one cent, emoji, Dec 31, card hold).
  final pbzRows = <List<Object>>[
    ['', 'TRANSAKCIJSKI RAČUN:', '', '', ''],
    ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'],
    [46037.08, 'Plaća/Mirovina', 'Neto plaća za 12/2025', 1500.0, ' EUR '],
    [46037.08, 'Isplata ATM', 'PBZ ATM TEST STREET ZAGREB', -550.0, ' EUR '],
    [46038.08, 'POS plaćanje', 'POS Revolut**0000* Dublin', -50.0, ' EUR '],
    [46038.08, 'POS plaćanje', 'POS Revolut**0000* Dublin', -50.0, ' EUR '],
    [46038.08, 'POS plaćanje', 'POS Revolut**0000* Dublin', -50.0, ' EUR '],
    [46039.08, 'POS plaćanje', 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB', -23.4, ' EUR '],
    [46040.08, 'Trajni nalog', 'Naplata kredita 0000000000', -250.0, ' EUR '],
    [46040.08, 'Naplaćene naknade', 'Naknada On-line bankarstvo - kreditni transfer', -0.33, ' EUR '],
    ['17.01.2026', 'POS plaćanje', 'ŠĐČĆŽ šđčćž €', '-1.234,56', 'EUR'],
    ['3.2.2026', 'Ostalo', 'VAL_01.01.2026.POVRAT', '1,234.5', 'EUR'],
    [46042.08, 'Ostalo', 'Zero', 0.0, ' EUR '],
    [46043.08, 'POS plaćanje', 'Tiny', -0.01, ' EUR '],
    [46044.08, 'POS plaćanje', 'Emoji 🍕 pizza', -12.99, ' EUR '],
    [46387.0, 'POS plaćanje', 'Leap day', -7.05, 'EUR'],
    [46037.08, 'POS plaćanje', 'REZERVACIJA hold', -10.0, 'EUR'],
  ];
  const pbzGolden = <Golden>[
    ('2026-01-15', 150000, 'Neto plaća za 12/2025', '2601151qhfet5'),
    ('2026-01-15', -55000, 'PBZ ATM TEST STREET ZAGREB', '2601151a36ujt'),
    ('2026-01-16', -5000, 'POS Revolut**0000* Dublin', '260116i4z9uw'),
    ('2026-01-16', -5000, 'POS Revolut**0000* Dublin', '260116i4z9uw_1'),
    ('2026-01-16', -5000, 'POS Revolut**0000* Dublin', '260116i4z9uw_2'),
    ('2026-01-17', -2340, 'PBZ POS PBZ7LIDL HRVATSKA ZAGREB', '260117hpzdpn'),
    ('2026-01-18', -25000, 'Naplata kredita 0000000000', '2601181i2k6ha'),
    ('2026-01-18', -33, 'Naknada On-line bankarstvo - kreditni transfer', '2601181g2gxot'),
    ('2026-01-17', -123456, 'ŠĐČĆŽ šđčćž €', '2601171bms5yl'),
    ('2026-02-03', 123450, 'VAL_01.01.2026.POVRAT', '2602034iu113'),
    ('2026-01-20', 0, 'Zero', '260120191xpba'),
    ('2026-01-21', -1, 'Tiny', '260121vkogl7'),
    ('2026-01-22', -1299, 'Emoji 🍕 pizza', '26012216bx95j'),
    ('2026-12-31', -705, 'Leap day', '2612311ubckhv'),
  ];

  final revRows = <List<Object>>[
    ['Type', 'Product', 'Started Date', 'Completed Date', 'Description', 'Amount', 'Fee', 'Currency', 'State', 'Balance'],
    ['Topup', 'Current', '2026-01-03 10:00:00', '2026-01-03 10:00:00', 'Top-up by *0000', 50.0, 0.0, 'EUR', 'COMPLETED', 50.0],
    ['Card Payment', 'Current', '2026-01-03 12:00:00', '2026-01-04 08:00:00', 'Wolt', -14.5, 0.0, 'EUR', 'COMPLETED', 35.5],
    ['Card Payment', 'Current', '2026-01-03 12:00:00', '2026-01-04 08:00:00', 'Wolt', -14.5, 0.0, 'EUR', 'COMPLETED', 35.5],
    ['Card Payment', 'Current', '2026-01-04 12:00:00', '', 'Example Café', -3.0, 0.0, 'EUR', 'PENDING', 32.5],
    ['Card Payment', 'Current', '2026-01-05 12:00:00', '2026-01-06 08:00:00', 'GraÅ¡o', -20.0, 0.0, 'EUR', 'COMPLETED', 15.5],
    ['Card Payment', 'Current', '2026-01-05 13:00:00', '2026-01-06 08:00:00', 'Fee Shop', -20.0, 0.5, 'EUR', 'COMPLETED', 15.5],
    ['Transfer', 'Current', '2026-01-06 12:00:00', '2026-01-06 12:00:00', 'Revolut Bank UAB', 10.0, 0.0, 'EUR', 'COMPLETED', 25.5],
  ];
  const revGolden = <Golden>[
    ('2026-01-03', 5000, 'Top-up by *0000', '260103qxa7gq'),
    ('2026-01-03', -1450, 'Wolt', '2601031kc6rso'),
    ('2026-01-03', -1450, 'Wolt', '2601031kc6rso_1'),
    ('2026-01-05', -2000, 'Grašo', '2601051pr53yc'),
    ('2026-01-05', -2050, 'Fee Shop', '26010598248v'),
    ('2026-01-06', 1000, 'Revolut Bank UAB', '2601061eifh0e'),
  ];

  List<Golden> view(ImportBatch b) => [for (final t in b.transactions) (t.date, t.amountMinor, t.description, t.id)];

  test('PBZ rows: same dates, amounts, descriptions and ids as v1', () {
    final b = parseRows(pbzRows)!;
    expect(b.source, 'pbz');
    expect(b.skipped, 1);
    expect(view(b), pbzGolden);
  });

  test('Revolut rows: same dates, amounts (fee deducted), repaired text and ids as v1', () {
    final b = parseRows(revRows)!;
    expect(b.source, 'revolut');
    expect(b.skipped, 1);
    expect(view(b), revGolden);
  });

  test('transactionId on its own matches every v1 vector', () {
    for (final g in [...pbzGolden, ...revGolden]) {
      final base = g.$4.split('_');
      final occ = base.length > 1 ? int.parse(base[1]) : 0;
      expect(transactionId(g.$1, g.$2, g.$3, occ), g.$4, reason: g.$3);
    }
  });

  test('more v1 vectors: leap day 2028, large amount, float amount, Revolut fees around a DST night', () {
    final rows = <List<Object>>[
      ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'],
      [46812.0, 'POS plaćanje', 'Leap 2028', -7.05, 'EUR'],
      [46813.0, 'POS plaćanje', 'Half cent pos', 0.125, 'EUR'],
      [46814.0, 'POS plaćanje', 'Big', -12345678.9, 'EUR'],
      [46815.0, 'POS plaćanje', 'Float', -0.1, 'EUR'],
    ];
    expect(view(parseRows(rows)!), const <Golden>[
      ('2028-02-29', -705, 'Leap 2028', '2802291k9hh6j'),
      ('2028-03-01', 13, 'Half cent pos', '28030114wzqsc'),
      ('2028-03-02', -1234567890, 'Big', '28030217rwc9e'),
      ('2028-03-03', -10, 'Float', '28030313whyj7'),
    ]);
    final rev = <List<Object>>[
      ['Type', 'Started Date', 'Description', 'Amount', 'Fee', 'State'],
      ['Card Payment', '2026-03-29 01:30:00', 'DST', -0.3, 0.1, 'COMPLETED'],
      ['Card Payment', '2026-03-29 02:30:00', 'DST2', '-1.10', '0.20', 'COMPLETED'],
    ];
    expect(view(parseRows(rev)!), const <Golden>[
      ('2026-03-29', -40, 'DST', '2603291e6pyu5'),
      ('2026-03-29', -130, 'DST2', '26032919ghhrz'),
    ]);
  });

  test('a negative half-cent amount rounds like v1 (Math.round: half towards +infinity)', () {
    final rows = <List<Object>>[
      ['DATUM', 'VRSTA TRANSAKCIJE', 'OPIS PLAĆANJA', 'IZNOS', 'VALUTA'],
      [46813.0, 'POS plaćanje', 'Half cent', -0.125, 'EUR'],
    ];
    // v1: r2(-0.125) = Math.round(-12.5) / 100 = -0.12 -> id 280301lxfin4 (Math.round takes halves towards +infinity).
    expect(view(parseRows(rows)!), const <Golden>[('2028-03-01', -12, 'Half cent', '280301lxfin4')]);
  });
}
