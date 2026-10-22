// M5 CSV exports, core half: exact decimals, RFC 4180 fields, which rows count. All data SYNTHETIC.
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

CategorizedTx _tx(String id, String date, int cents,
        {String cat = 'Shopping',
        String desc = 'Test shop',
        String? note,
        String? matchedTo,
        bool deleted = false,
        String source = 'pbz'}) =>
    CategorizedTx(
        Tx(id: id, source: source, date: date, amount: cents, description: desc, note: note, matchedTo: matchedTo, deleted: deleted),
        cat,
        kindOf(cat));

void main() {
  group('centsToDecimal', () {
    test('exact for every cents value, two fractional digits, no negative zero', () {
      const table = {
        0: '0.00',
        1: '0.01',
        -1: '-0.01',
        10: '0.10',
        99: '0.99',
        100: '1.00',
        -123456: '-1234.56',
        100000000: '1000000.00',
        100000000000000: '1000000000000.00',
        -100000000000001: '-1000000000000.01',
        9007199254740993: '90071992547409.93', // past 2^53: a double would round, an int does not
      };
      table.forEach((cents, want) => expect(centsToDecimal(cents), want, reason: '$cents'));
    });
  });

  group('csvField', () {
    test('plain text stays as is; quotes, commas, LF and CR are quoted with quotes doubled', () {
      expect(csvField('plain text'), 'plain text');
      expect(csvField(''), '');
      expect(csvField('a,b'), '"a,b"');
      expect(csvField('say "hi"'), '"say ""hi"""');
      expect(csvField('two\nlines'), '"two\nlines"');
      expect(csvField('cr\rhere'), '"cr\rhere"');
      expect(csvField('čćšžđ €'), 'čćšžđ €', reason: 'UTF-8 as is, no BOM, no escaping');
    });
  });

  group('transactionsCsv', () {
    test('header constant, one LF-terminated record per live row', () {
      final s = transactionsCsv([_tx('a', '2026-01-02', -100, note: 'n')]);
      expect(s, '$transactionsCsvHeader\n2026-01-02,-1.00,Shopping,Test shop,pbz,n\n');
    });

    test('deleted rows and hand-added entries replaced by a bank row that is here are left out', () {
      final s = transactionsCsv([
        _tx('bank', '2026-01-02', -100),
        _tx('m', '2026-01-02', -100, source: 'manual', matchedTo: 'bank', note: 'cash'),
        _tx('gone', '2026-01-03', -200, deleted: true),
      ]);
      expect(s.split('\n').where((l) => l.isNotEmpty), hasLength(2));
      expect(s, isNot(contains('cash')));
      expect(s, isNot(contains('-2.00')));
    });

    test('a replaced entry whose bank row is not here yet still counts (matchPending)', () {
      const pending = CategorizedTx(
          Tx(id: 'm', source: 'manual', date: '2026-01-02', amount: -100, matchedTo: 'later', note: 'cash', matchPending: true),
          'Eating out',
          BudgetKind.flex);
      expect(transactionsCsv([pending]), contains('2026-01-02,-1.00,Eating out,,manual,cash\n'));
    });

    test('the category column is the resolved category, not the pinned one', () {
      const t =
          CategorizedTx(Tx(id: 'a', source: 'pbz', date: '2026-01-02', amount: -100, description: 'LIDL'), 'Groceries', BudgetKind.flex);
      expect(transactionsCsv([t]).split('\n')[1], '2026-01-02,-1.00,Groceries,LIDL,pbz,');
    });
  });

  group('monthlySummaryCsv', () {
    final cats = spendingCategories;

    test('header lists every spending category in order', () {
      expect(monthlySummaryCsvHeader, 'month,${cats.join(',')},total');
      expect(monthlySummaryCsv(const []), '$monthlySummaryCsvHeader\n');
      expect(cats, containsAll(['Rent', 'Loan', 'Bills & subscriptions', 'Groceries', 'Cash', 'Bank fees']));
      expect(cats, isNot(contains('Salary')));
      expect(cats, isNot(contains('Internal transfer')));
    });

    test('a month with only income, transfers or deleted rows has no line', () {
      final rows = monthlySummaryCsv([
        _tx('1', '2026-01-05', 150000, cat: 'Salary'),
        _tx('2', '2026-02-05', -5000, cat: 'Internal transfer'),
        _tx('3', '2026-03-05', -700, cat: 'Groceries', deleted: true),
        _tx('4', '2026-04-05', -700, cat: 'Groceries'),
      ]).trim().split('\n');
      expect(rows, hasLength(2));
      expect(rows[1].startsWith('2026-04,'), isTrue);
    });

    test('a net refund in a category prints negative; the total still equals the sum of the cells', () {
      final line = monthlySummaryCsv([
        _tx('1', '2026-01-02', -1000, cat: 'Shopping'),
        _tx('2', '2026-01-03', 1500, cat: 'Shopping'),
        _tx('3', '2026-01-04', -250, cat: 'Groceries'),
      ]).trim().split('\n')[1].split(',');
      expect(line[1 + cats.indexOf('Shopping')], '-5.00');
      expect(line[1 + cats.indexOf('Groceries')], '2.50');
      expect(line.last, '-2.50');
      expect(line, hasLength(cats.length + 2));
    });

    test('replaced hand-added entries do not count twice', () {
      final line = monthlySummaryCsv([
        _tx('bank', '2026-01-02', -1000, cat: 'Groceries'),
        _tx('m', '2026-01-02', -1000, cat: 'Groceries', source: 'manual', matchedTo: 'bank'),
      ]).trim().split('\n')[1].split(',');
      expect(line.last, '10.00');
    });
  });
}
