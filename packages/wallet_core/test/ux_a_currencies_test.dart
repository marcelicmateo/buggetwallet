// Stage UX-A core, points 1-2 (docs/context/UX_SPEC.md): currency table, minor digits through FX, prevalentCurrency.
// Written from the spec, not the implementation. All data SYNTHETIC.
//
// FX convention: a rate is wallet units per foreign unit x FxRate.scale. Updated by core-builder to the lead's storage
// rule (2026-11-01): amounts are stored at storageDigitsOf (every fiat currency in hundredths as before, BTC in
// satoshis), so home stored = foreign stored x rate / scale x 10^(homeStorage - foreignStorage).
import 'package:test/test.dart';
import 'package:wallet_core/wallet_core.dart';

const _t = Timeout(Duration(seconds: 30));

/// 2026-10-10 00:00 UTC in ms.
const _now = 1791590400000;

Tx _pay(int i, String currency, {int amount = -1000}) => Tx(
    id: 'ux-$i-$currency', source: 'pbz', date: '2026-10-0${1 + i % 9}', amount: amount, currency: currency, description: 'Synthetic $i');

List<Tx> _mix(int total, String x, int inX, {String other = 'EUR'}) => [
      for (var i = 0; i < total; i++) _pay(i, i < inX ? x : other),
    ];

void main() {
  group('currency table', () {
    test('minorDigitsOf: JPY 0, KWD 3, EUR 2, BTC 8, unknown 2', () {
      expect(minorDigitsOf('JPY'), 0);
      expect(minorDigitsOf('KWD'), 3);
      expect(minorDigitsOf('EUR'), 2);
      expect(minorDigitsOf('USD'), 2);
      expect(minorDigitsOf('BTC'), 8);
      expect(minorDigitsOf('ZZZ'), 2);
      expect(minorDigitsOf(''), 2);
      expect(minorDigitsOf('eur'), 2, reason: 'codes are upper case; anything else is unknown');
      expect([
        for (final c in ['JPY', 'KWD', 'EUR', 'BTC']) storageDigitsOf(c)
      ], [
        2,
        2,
        2,
        8
      ], reason: 'storage rule');
    }, timeout: _t);

    test('allCurrencies: unique three-capital codes, EUR present, BTC is the crypto one', () {
      final codes = allCurrencies.map((c) => c.code).toList();
      expect(codes.toSet().length, codes.length, reason: 'no duplicate code');
      for (final c in allCurrencies) {
        expect(RegExp(r'^[A-Z]{3}$').hasMatch(c.code), isTrue, reason: c.code);
        expect(c.name, isNotEmpty, reason: c.code);
        expect(c.minorDigits, inInclusiveRange(0, 8), reason: c.code);
      }
      expect(codes, containsAll(['EUR', 'USD', 'JPY', 'KWD', 'BTC']));
      final btc = currencyInfo('BTC')!;
      expect((btc.crypto, btc.minorDigits), (true, 8));
      expect(currencyInfo('EUR')!.crypto, isFalse);
      expect(allCurrencies.where((c) => c.crypto).map((c) => c.code), contains('BTC'));
      expect(currencyInfo('ZZZ'), isNull);
    }, timeout: _t);

    test('minorDigitsOf agrees with the table for every entry', () {
      for (final c in allCurrencies) {
        expect(minorDigitsOf(c.code), c.minorDigits, reason: c.code);
      }
    }, timeout: _t);
  });

  group('FX with other digits', () {
    late WalletRepo repo;
    setUp(() => repo = WalletRepo.inMemory(now: () => _now));
    tearDown(() => repo.close());

    Tx row(String cur, int amount) =>
        Tx(id: 'fx-$cur', source: 'revolut', date: '2026-10-05', amount: amount, currency: cur, description: 'Synthetic $cur');

    int? home(Tx t) => homeAmount(t, repo.settings());

    test('JPY: 1,000 yen (stored 100000 hundredths) at 0.0065 EUR per yen = 6.50 EUR = 650 cents', () {
      repo.setFxRate('JPY', 6500);
      expect(home(row('JPY', -100000)), -650);
    }, timeout: _t);

    test('KWD: 1.00 dinar (stored 100) at 3 EUR per dinar = 300 cents; 2.50 KWD = 750 cents', () {
      repo.setFxRate('KWD', 3000000);
      expect(home(row('KWD', 100)), 300);
      expect(home(row('KWD', -250)), -750);
    }, timeout: _t);

    test('BTC: 1 BTC (10^8 minor) at 50 EUR = 5,000 cents; 0.01 BTC = 50 cents', () {
      repo.setFxRate('BTC', 50000000);
      expect(home(row('BTC', 100000000)), 5000);
      expect(home(row('BTC', 1000000)), 50);
    }, timeout: _t);

    test('one satoshi is below half a cent at a small rate: rounds to 0, never negative or inflated', () {
      repo.setFxRate('BTC', 50000000);
      expect(home(row('BTC', 1)), 0);
      expect(home(row('BTC', -1)), 0);
    }, timeout: _t);

    test('setFxRate accepts BTC, refuses the wallet currency and unknown codes', () {
      repo.setFxRate('BTC', 50000000);
      expect(repo.settings().fxRates.keys, contains('BTC'));
      expect(() => repo.setFxRate('EUR', 1000000), throwsArgumentError);
      expect(() => repo.setFxRate('ZZZ', 1000000), throwsArgumentError, reason: 'well formed but not in allCurrencies');
      expect(() => repo.setFxRate('btc', 1000000), throwsArgumentError);
      expect(() => repo.setFxRate('', 1000000), throwsArgumentError);
      expect(repo.settings().fxRates.keys.toList(), ['BTC'], reason: 'refusals write nothing');
    }, timeout: _t);

    test('a row in the wallet currency is never converted', () {
      repo.setFxRate('JPY', 6500);
      expect(home(row('EUR', -1234)), -1234);
    }, timeout: _t);
  });

  group('prevalentCurrency', () {
    test('9 payments all in USD: too few, null', () {
      expect(prevalentCurrency(_mix(9, 'USD', 9), 'EUR'), isNull);
    }, timeout: _t);

    test('10 payments, 8 in USD (80 %): USD', () {
      expect(prevalentCurrency(_mix(10, 'USD', 8), 'EUR'), 'USD');
    }, timeout: _t);

    test('10 payments, 7 in USD (70 %): null', () {
      expect(prevalentCurrency(_mix(10, 'USD', 7), 'EUR'), isNull);
    }, timeout: _t);

    test('79 % vs 80 % at 100 rows: 79 null, 80 USD, 81 USD', () {
      expect(prevalentCurrency(_mix(100, 'USD', 79), 'EUR'), isNull);
      expect(prevalentCurrency(_mix(100, 'USD', 80), 'EUR'), 'USD');
      expect(prevalentCurrency(_mix(100, 'USD', 81), 'EUR'), 'USD');
    }, timeout: _t);

    test('10 rows all USD: USD; empty list: null', () {
      expect(prevalentCurrency(_mix(10, 'USD', 10), 'EUR'), 'USD');
      expect(prevalentCurrency(const <Tx>[], 'EUR'), isNull);
    }, timeout: _t);

    test('counts by number, never by amount: one huge EUR row does not tip it', () {
      final txs = [
        for (var i = 0; i < 8; i++) _pay(i, 'USD', amount: -100),
        _pay(8, 'EUR', amount: -90000000),
        _pay(9, 'EUR', amount: -100),
      ];
      expect(prevalentCurrency(txs, 'EUR'), 'USD');
    }, timeout: _t);

    test('a few huge USD rows do not make USD prevalent either', () {
      final txs = [
        for (var i = 0; i < 7; i++) _pay(i, 'EUR', amount: -100),
        for (var i = 7; i < 10; i++) _pay(i, 'USD', amount: -90000000),
      ];
      expect(prevalentCurrency(txs, 'EUR'), isNull);
    }, timeout: _t);

    test('X equal to the wallet currency: null', () {
      expect(prevalentCurrency(_mix(20, 'EUR', 20), 'EUR'), isNull);
      expect(prevalentCurrency(_mix(20, 'USD', 20), 'USD'), isNull);
    }, timeout: _t);

    test('two foreign currencies split the rows: neither reaches 80 %', () {
      final txs = [
        for (var i = 0; i < 5; i++) _pay(i, 'USD'),
        for (var i = 5; i < 10; i++) _pay(i, 'GBP'),
      ];
      expect(prevalentCurrency(txs, 'EUR'), isNull);
    }, timeout: _t);

    test('works for a non-EUR wallet: mostly EUR rows in a USD wallet offers EUR', () {
      expect(prevalentCurrency(_mix(10, 'EUR', 9, other: 'USD'), 'USD'), 'EUR');
    }, timeout: _t);
  });
}
