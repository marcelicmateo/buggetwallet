/// Currencies (Stage UX-A): every circulating ISO 4217 code with its English name and minor digits, plus Bitcoin. Pure
/// data, no bank format. The importer reads amounts with these digits; `wallet_core` re-exports the table
/// (`src/currencies.dart`).
///
/// Left out on purpose: ISO fund codes and units of account (BOV, CHE, CHW, CLF, COU, MXV, USN, UYI, UYW, XDR, XSU,
/// XUA), metals (XAU, XAG, XPD, XPT) and test codes (XTS, XXX). Kept although withdrawn, because old statements carry
/// them: ANG, BGN, HRK.
library;

/// One currency: [code] (three capital letters), [name] in English, [minorDigits] (the digits after the decimal point
/// of one minor unit: EUR 2, JPY 0, KWD 3, BTC 8) and whether it is a [crypto] currency.
class CurrencyInfo {
  final String code;
  final String name;
  final int minorDigits;
  final bool crypto;
  const CurrencyInfo(this.code, this.name, this.minorDigits, {this.crypto = false});

  @override
  String toString() => code;
}

/// Every currency the app knows, ISO 4217 by code, then the crypto ones (BTC).
const List<CurrencyInfo> allCurrencies = [
  CurrencyInfo('AED', 'UAE Dirham', 2),
  CurrencyInfo('AFN', 'Afghani', 2),
  CurrencyInfo('ALL', 'Lek', 2),
  CurrencyInfo('AMD', 'Armenian Dram', 2),
  CurrencyInfo('ANG', 'Netherlands Antillean Guilder', 2),
  CurrencyInfo('AOA', 'Kwanza', 2),
  CurrencyInfo('ARS', 'Argentine Peso', 2),
  CurrencyInfo('AUD', 'Australian Dollar', 2),
  CurrencyInfo('AWG', 'Aruban Florin', 2),
  CurrencyInfo('AZN', 'Azerbaijan Manat', 2),
  CurrencyInfo('BAM', 'Convertible Mark', 2),
  CurrencyInfo('BBD', 'Barbados Dollar', 2),
  CurrencyInfo('BDT', 'Taka', 2),
  CurrencyInfo('BGN', 'Bulgarian Lev', 2),
  CurrencyInfo('BHD', 'Bahraini Dinar', 3),
  CurrencyInfo('BIF', 'Burundi Franc', 0),
  CurrencyInfo('BMD', 'Bermudian Dollar', 2),
  CurrencyInfo('BND', 'Brunei Dollar', 2),
  CurrencyInfo('BOB', 'Boliviano', 2),
  CurrencyInfo('BRL', 'Brazilian Real', 2),
  CurrencyInfo('BSD', 'Bahamian Dollar', 2),
  CurrencyInfo('BTN', 'Ngultrum', 2),
  CurrencyInfo('BWP', 'Pula', 2),
  CurrencyInfo('BYN', 'Belarusian Ruble', 2),
  CurrencyInfo('BZD', 'Belize Dollar', 2),
  CurrencyInfo('CAD', 'Canadian Dollar', 2),
  CurrencyInfo('CDF', 'Congolese Franc', 2),
  CurrencyInfo('CHF', 'Swiss Franc', 2),
  CurrencyInfo('CLP', 'Chilean Peso', 0),
  CurrencyInfo('CNY', 'Yuan Renminbi', 2),
  CurrencyInfo('COP', 'Colombian Peso', 2),
  CurrencyInfo('CRC', 'Costa Rican Colon', 2),
  CurrencyInfo('CUP', 'Cuban Peso', 2),
  CurrencyInfo('CVE', 'Cabo Verde Escudo', 2),
  CurrencyInfo('CZK', 'Czech Koruna', 2),
  CurrencyInfo('DJF', 'Djibouti Franc', 0),
  CurrencyInfo('DKK', 'Danish Krone', 2),
  CurrencyInfo('DOP', 'Dominican Peso', 2),
  CurrencyInfo('DZD', 'Algerian Dinar', 2),
  CurrencyInfo('EGP', 'Egyptian Pound', 2),
  CurrencyInfo('ERN', 'Nakfa', 2),
  CurrencyInfo('ETB', 'Ethiopian Birr', 2),
  CurrencyInfo('EUR', 'Euro', 2),
  CurrencyInfo('FJD', 'Fiji Dollar', 2),
  CurrencyInfo('FKP', 'Falkland Islands Pound', 2),
  CurrencyInfo('GBP', 'Pound Sterling', 2),
  CurrencyInfo('GEL', 'Lari', 2),
  CurrencyInfo('GHS', 'Ghana Cedi', 2),
  CurrencyInfo('GIP', 'Gibraltar Pound', 2),
  CurrencyInfo('GMD', 'Dalasi', 2),
  CurrencyInfo('GNF', 'Guinean Franc', 0),
  CurrencyInfo('GTQ', 'Quetzal', 2),
  CurrencyInfo('GYD', 'Guyana Dollar', 2),
  CurrencyInfo('HKD', 'Hong Kong Dollar', 2),
  CurrencyInfo('HNL', 'Lempira', 2),
  CurrencyInfo('HRK', 'Croatian Kuna', 2),
  CurrencyInfo('HTG', 'Gourde', 2),
  CurrencyInfo('HUF', 'Forint', 2),
  CurrencyInfo('IDR', 'Rupiah', 2),
  CurrencyInfo('ILS', 'New Israeli Sheqel', 2),
  CurrencyInfo('INR', 'Indian Rupee', 2),
  CurrencyInfo('IQD', 'Iraqi Dinar', 3),
  CurrencyInfo('IRR', 'Iranian Rial', 2),
  CurrencyInfo('ISK', 'Iceland Krona', 0),
  CurrencyInfo('JMD', 'Jamaican Dollar', 2),
  CurrencyInfo('JOD', 'Jordanian Dinar', 3),
  CurrencyInfo('JPY', 'Yen', 0),
  CurrencyInfo('KES', 'Kenyan Shilling', 2),
  CurrencyInfo('KGS', 'Som', 2),
  CurrencyInfo('KHR', 'Riel', 2),
  CurrencyInfo('KMF', 'Comorian Franc', 0),
  CurrencyInfo('KPW', 'North Korean Won', 2),
  CurrencyInfo('KRW', 'Won', 0),
  CurrencyInfo('KWD', 'Kuwaiti Dinar', 3),
  CurrencyInfo('KYD', 'Cayman Islands Dollar', 2),
  CurrencyInfo('KZT', 'Tenge', 2),
  CurrencyInfo('LAK', 'Lao Kip', 2),
  CurrencyInfo('LBP', 'Lebanese Pound', 2),
  CurrencyInfo('LKR', 'Sri Lanka Rupee', 2),
  CurrencyInfo('LRD', 'Liberian Dollar', 2),
  CurrencyInfo('LSL', 'Loti', 2),
  CurrencyInfo('LYD', 'Libyan Dinar', 3),
  CurrencyInfo('MAD', 'Moroccan Dirham', 2),
  CurrencyInfo('MDL', 'Moldovan Leu', 2),
  CurrencyInfo('MGA', 'Malagasy Ariary', 2),
  CurrencyInfo('MKD', 'Denar', 2),
  CurrencyInfo('MMK', 'Kyat', 2),
  CurrencyInfo('MNT', 'Tugrik', 2),
  CurrencyInfo('MOP', 'Pataca', 2),
  CurrencyInfo('MRU', 'Ouguiya', 2),
  CurrencyInfo('MUR', 'Mauritius Rupee', 2),
  CurrencyInfo('MVR', 'Rufiyaa', 2),
  CurrencyInfo('MWK', 'Malawi Kwacha', 2),
  CurrencyInfo('MXN', 'Mexican Peso', 2),
  CurrencyInfo('MYR', 'Malaysian Ringgit', 2),
  CurrencyInfo('MZN', 'Mozambique Metical', 2),
  CurrencyInfo('NAD', 'Namibia Dollar', 2),
  CurrencyInfo('NGN', 'Naira', 2),
  CurrencyInfo('NIO', 'Cordoba Oro', 2),
  CurrencyInfo('NOK', 'Norwegian Krone', 2),
  CurrencyInfo('NPR', 'Nepalese Rupee', 2),
  CurrencyInfo('NZD', 'New Zealand Dollar', 2),
  CurrencyInfo('OMR', 'Rial Omani', 3),
  CurrencyInfo('PAB', 'Balboa', 2),
  CurrencyInfo('PEN', 'Sol', 2),
  CurrencyInfo('PGK', 'Kina', 2),
  CurrencyInfo('PHP', 'Philippine Peso', 2),
  CurrencyInfo('PKR', 'Pakistan Rupee', 2),
  CurrencyInfo('PLN', 'Zloty', 2),
  CurrencyInfo('PYG', 'Guarani', 0),
  CurrencyInfo('QAR', 'Qatari Rial', 2),
  CurrencyInfo('RON', 'Romanian Leu', 2),
  CurrencyInfo('RSD', 'Serbian Dinar', 2),
  CurrencyInfo('RUB', 'Russian Ruble', 2),
  CurrencyInfo('RWF', 'Rwanda Franc', 0),
  CurrencyInfo('SAR', 'Saudi Riyal', 2),
  CurrencyInfo('SBD', 'Solomon Islands Dollar', 2),
  CurrencyInfo('SCR', 'Seychelles Rupee', 2),
  CurrencyInfo('SDG', 'Sudanese Pound', 2),
  CurrencyInfo('SEK', 'Swedish Krona', 2),
  CurrencyInfo('SGD', 'Singapore Dollar', 2),
  CurrencyInfo('SHP', 'Saint Helena Pound', 2),
  CurrencyInfo('SLE', 'Leone', 2),
  CurrencyInfo('SOS', 'Somali Shilling', 2),
  CurrencyInfo('SRD', 'Surinam Dollar', 2),
  CurrencyInfo('SSP', 'South Sudanese Pound', 2),
  CurrencyInfo('STN', 'Dobra', 2),
  CurrencyInfo('SVC', 'El Salvador Colon', 2),
  CurrencyInfo('SYP', 'Syrian Pound', 2),
  CurrencyInfo('SZL', 'Lilangeni', 2),
  CurrencyInfo('THB', 'Baht', 2),
  CurrencyInfo('TJS', 'Somoni', 2),
  CurrencyInfo('TMT', 'Turkmenistan New Manat', 2),
  CurrencyInfo('TND', 'Tunisian Dinar', 3),
  CurrencyInfo('TOP', 'Pa\'anga', 2),
  CurrencyInfo('TRY', 'Turkish Lira', 2),
  CurrencyInfo('TTD', 'Trinidad and Tobago Dollar', 2),
  CurrencyInfo('TWD', 'New Taiwan Dollar', 2),
  CurrencyInfo('TZS', 'Tanzanian Shilling', 2),
  CurrencyInfo('UAH', 'Hryvnia', 2),
  CurrencyInfo('UGX', 'Uganda Shilling', 0),
  CurrencyInfo('USD', 'US Dollar', 2),
  CurrencyInfo('UYU', 'Peso Uruguayo', 2),
  CurrencyInfo('UZS', 'Uzbekistan Sum', 2),
  CurrencyInfo('VED', 'Bolivar Digital', 2),
  CurrencyInfo('VES', 'Bolivar Soberano', 2),
  CurrencyInfo('VND', 'Dong', 0),
  CurrencyInfo('VUV', 'Vatu', 0),
  CurrencyInfo('WST', 'Tala', 2),
  CurrencyInfo('XAF', 'CFA Franc BEAC', 0),
  CurrencyInfo('XCD', 'East Caribbean Dollar', 2),
  CurrencyInfo('XCG', 'Caribbean Guilder', 2),
  CurrencyInfo('XOF', 'CFA Franc BCEAO', 0),
  CurrencyInfo('XPF', 'CFP Franc', 0),
  CurrencyInfo('YER', 'Yemeni Rial', 2),
  CurrencyInfo('ZAR', 'Rand', 2),
  CurrencyInfo('ZMW', 'Zambian Kwacha', 2),
  CurrencyInfo('ZWG', 'Zimbabwe Gold', 2),
  CurrencyInfo('BTC', 'Bitcoin', 8, crypto: true),
];

final Map<String, CurrencyInfo> _byCode = {for (final c in allCurrencies) c.code: c};

/// The entry of [code] (exact, upper case), or null for a code the table does not hold.
CurrencyInfo? currencyInfo(String code) => _byCode[code];

/// The minor digits of [code] ([CurrencyInfo.minorDigits]); 2 for a code the table does not hold (the scale every
/// amount had before Stage UX-A).
int minorDigitsOf(String code) => _byCode[code]?.minorDigits ?? 2;

/// 10^[digits] for 0..18 (an int on the VM; exact on the web up to 10^15).
int pow10(int digits) {
  var p = 1;
  for (var i = 0; i < digits; i++) {
    p *= 10;
  }
  return p;
}
