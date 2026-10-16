// Unit tests for the pure logic in app/index.html (between /*CORE-START*/ and /*CORE-END*/).
// All fixtures here are synthetic. Never paste real bank rows into this file.
const test = require("node:test");
const assert = require("node:assert/strict");
const { loadCore } = require("./load-core");

const C = loadCore();

// ---------- synthetic fixtures ----------
const PBZ_ROWS = [
  ["", "", "", "", ""],
  ["", "TRANSAKCIJSKI RAČUN:", "", "", ""],
  ["", "HR0000000000000000000", "", "", ""],
  ["", "OD:", "DO:", "", ""],
  [" ", "01.01.2026", "31.01.2026", "", ""],
  ["DATUM", "VRSTA TRANSAKCIJE", "OPIS PLAĆANJA", "IZNOS", "VALUTA"],
  [46037.08, "Plaća/Mirovina", "Neto plaća za 12/2025", 1500, " EUR "],
  [46037.08, "Isplata ATM", "PBZ ATM TEST STREET ZAGREB", -550, " EUR "],
  [46038.08, "POS plaćanje", "POS Revolut**0000* Dublin", -50, " EUR "],
  [46038.08, "POS plaćanje", "POS Revolut**0000* Dublin", -50, " EUR "],
  [46039.08, "POS plaćanje", "PBZ POS PBZ7LIDL HRVATSKA ZAGREB", -23.4, " EUR "],
  [46040.08, "Trajni nalog", "Naplata kredita 0000000000", -250, " EUR "],
  [46040.08, "Naplaćene naknade", "Naknada On-line bankarstvo - kreditni transfer", -0.33, " EUR "],
  [46041.08, "POS plaćanje", "REZERVACIJA POS PLAĆANJE EXAMPLE SHOP", -10, " EUR "],
  [46042.08, "Ostalo", "VAL_01.01.2026.POVRAT", 300, " EUR "],
];
const REV_ROWS = [
  ["Type", "Product", "Started Date", "Completed Date", "Description", "Amount", "Fee", "Currency", "State", "Balance"],
  ["Topup", "Current", "2026-01-03 10:00:00", "2026-01-03 10:00:00", "Top-up by *0000", 50, 0, "EUR", "COMPLETED", 50],
  ["Card Payment", "Current", "2026-01-03 12:00:00", "2026-01-04 08:00:00", "Wolt", -14.5, 0, "EUR", "COMPLETED", 35.5],
  ["Card Payment", "Current", "2026-01-04 12:00:00", "", "Example Café", -3, 0, "EUR", "PENDING", 32.5],
  ["Card Payment", "Current", "2026-01-05 12:00:00", "2026-01-06 08:00:00", "GraÅ¡o", -20, 0, "EUR", "COMPLETED", 15.5],
  ["Transfer", "Current", "2026-01-06 12:00:00", "2026-01-06 12:00:00", "Revolut Bank UAB", 10, 0, "EUR", "COMPLETED", 25.5],
];

test("parses a PBZ export, skips card holds, keeps signs", () => {
  const p = C.parseRows(PBZ_ROWS);
  assert.equal(p.source, "pbz");
  assert.equal(p.items.length, 8);
  assert.ok(!p.items.some(i => /REZERVACIJA/.test(i.m)));
  assert.equal(p.items[0].d, "2026-01-15");
  assert.equal(p.items[0].a, 1500);
});

test("ids are stable across imports and unique for identical rows", () => {
  const a = C.parseRows(PBZ_ROWS).items.map(i => i.i);
  const b = C.parseRows(PBZ_ROWS).items.map(i => i.i);
  assert.deepEqual(a, b);
  assert.equal(new Set(a).size, a.length);
});

test("parses a Revolut statement, drops pending rows, repairs broken UTF-8", () => {
  const p = C.parseRows(REV_ROWS);
  assert.equal(p.source, "rev");
  assert.equal(p.items.length, 4);
  assert.ok(p.items.some(i => i.m === "Grašo"));
});

test("categorises PBZ rows", () => {
  const cat = m => C.autoCat(C.parseRows(PBZ_ROWS).items.find(i => i.m.includes(m)), "pbz");
  assert.equal(cat("Neto plaća"), "Salary");
  assert.equal(cat("PBZ ATM"), "Rent");
  assert.equal(cat("Revolut"), "Internal transfer");
  assert.equal(cat("LIDL"), "Groceries");
  assert.equal(cat("Naplata kredita"), "Loan");
  assert.equal(cat("kreditni transfer"), "Bank fees");
  assert.equal(cat("POVRAT"), "Extra income");
});

test("categorises Revolut rows and applies personal patterns first", () => {
  const items = C.parseRows(REV_ROWS).items;
  const cat = m => C.autoCat(items.find(i => i.m === m), "rev");
  assert.equal(cat("Top-up by *0000"), "Internal transfer");
  assert.equal(cat("Wolt"), "Food delivery");
  assert.equal(cat("Revolut Bank UAB"), "To people");
  assert.equal(cat("Grašo"), "Shopping");
  C.setUserPatterns([["Eating out", "gra.o"]]);
  assert.equal(cat("Grašo"), "Eating out");
  C.setUserPatterns([]);
});

test("payday period: budget, rollover and days left", () => {
  const months = {
    "pbz-2026-01": { source: "pbz", items: C.parseRows(PBZ_ROWS).items },
    "rev-2026-01": { source: "rev", items: C.parseRows(REV_ROWS).items },
  };
  const items = C.flatten(months, {});
  const st = { salary: 1500, rent: 550, loan: 250, subs: 0, paydayDay: 15, periodStart: "2026-01-15", incomeMode: "planned" };
  const P = C.computePeriod(items, st, [{ monthly: 100 }], "2026-01-20");
  assert.equal(P.end, "2026-02-15");
  assert.equal(P.len, 31);
  assert.equal(P.daysLeft, 26);
  assert.equal(P.flexBudget, 600);           // 1500 - 550 - 250 - 0 - 100
  assert.equal(P.spent, 23.73);               // Lidl 23.40 + bank fee 0.33 (from 15 Jan on)
  assert.equal(P.remaining, 576.27);
});

test("affordability verdicts", () => {
  const P = { flexBudget: 600, spent: 100, daysLeft: 20, planDaily: 20, allowanceToday: 25, safeToday: 25, remaining: 500 };
  assert.equal(C.affordability(50, P).verdict, "now");
  assert.equal(C.affordability(300, P).verdict, "tight");
  assert.equal(C.affordability(700, P).verdict, "later");
});

test("month summary ignores internal transfers", () => {
  const months = { "pbz-2026-01": { source: "pbz", items: C.parseRows(PBZ_ROWS).items } };
  const s = C.monthSummary(C.flatten(months, {}), "2026-01");
  assert.equal(s.income, 1800);
  assert.equal(s.out, 823.73);
});
