"""Generate SYNTHETIC bank export fixtures for importer tests. No real data.

PBZ-style .xls (BIFF8) with enough distinct strings to force SST CONTINUE records,
Revolut-style .xlsx with date cells and mojibake text, and a Revolut-style CSV.
Usage: python3 tools/make_fixtures.py packages/wallet_importer/test/fixtures
"""
import sys, os, datetime, random
import xlwt, openpyxl

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
rnd = random.Random(42)

# ---------- PBZ-style .xls ----------
wb = xlwt.Workbook(encoding="utf-8")
ws = wb.add_sheet("Sheet1")
ws.write(3, 1, "TRANSAKCIJSKI RAČUN:")
ws.write(4, 1, "HR0000000000000000000")
ws.write(6, 1, "OD:"); ws.write(6, 2, "DO:")
ws.write(7, 0, " "); ws.write(7, 1, "01.01.2026"); ws.write(7, 2, "31.03.2026")
for c, h in enumerate(["DATUM", "VRSTA TRANSAKCIJE", "OPIS PLAĆANJA", "IZNOS", "VALUTA"]):
    ws.write(9, c, h)
rows = [
    (46037.0833, "Plaća/Mirovina", "Neto plaća za 12/2025", 1500.0),
    (46037.0833, "Isplata ATM", "PBZ ATM TEST ULICA ZAGREB", -550.0),
    (46038.0833, "POS plaćanje", "POS Revolut**0000* Dublin", -50.0),
    (46038.0833, "POS plaćanje", "POS Revolut**0000* Dublin", -50.0),
    (46039.0833, "POS plaćanje", "PBZ POS PBZ7LIDL HRVATSKA ZAGREB", -23.4),
    (46040.0833, "Trajni nalog", "Naplata kredita 0000000000", -250.0),
    (46040.0833, "Naplaćene naknade", "Naknada On-line bankarstvo - kreditni transfer", -0.33),
    (46041.0833, "POS plaćanje", "REZERVACIJA POS PLAĆANJE EXAMPLE SHOP", -10.0),
    (46042.0833, "Ostalo", "VAL_01.01.2026.POVRAT", 300.0),
]
# many distinct strings (> 8 KB of SST) so the SST spills into CONTINUE records
for k in range(400):
    rows.append((46043.0833 + k % 60, "Plaćanje putem direktnih kanala",
                 "Plaćanje po računu br. %05d-ŠĐČĆŽ-%s" % (k, "x" * rnd.randint(5, 40)),
                 -round(rnd.uniform(1, 200), 2)))
for r, (d, t, m, a) in enumerate(rows, start=10):
    ws.write(r, 0, d); ws.write(r, 1, t); ws.write(r, 2, m); ws.write(r, 3, a); ws.write(r, 4, " EUR ")
wb.save(os.path.join(out, "pbz_synthetic.xls"))

# ---------- Revolut-style .xlsx ----------
wb2 = openpyxl.Workbook(); s = wb2.active
s.append(["Type", "Product", "Started Date", "Completed Date", "Description", "Amount", "Fee", "Currency", "State", "Balance"])
def dt(day, h): return datetime.datetime(2026, 1, day, h, 15, 0)
s.append(["Topup", "Current", dt(3, 10), dt(3, 10), "Top-up by *0000", 50, 0, "EUR", "COMPLETED", 50])
s.append(["Card Payment", "Current", dt(3, 12), dt(4, 8), "Wolt", -14.5, 0, "EUR", "COMPLETED", 35.5])
s.append(["Card Payment", "Current", dt(4, 12), None, "Example Cafe", -3, 0, "EUR", "PENDING", 32.5])
s.append(["Card Payment", "Current", dt(5, 12), dt(6, 8), "GraÅ¡o", -20, 0.5, "EUR", "COMPLETED", 15])
s.append(["Transfer", "Current", dt(6, 12), dt(6, 12), "Revolut Bank UAB", 10, 0, "EUR", "COMPLETED", 25])
s.append(["Card Payment", "Current", dt(7, 9), dt(7, 9), "Wolt", -14.5, 0, "EUR", "COMPLETED", 10.5])
s.append(["Card Payment", "Current", dt(7, 9), dt(7, 9), "Wolt", -14.5, 0, "EUR", "COMPLETED", -4])
wb2.save(os.path.join(out, "revolut_synthetic.xlsx"))

# ---------- Revolut-style CSV ----------
with open(os.path.join(out, "revolut_synthetic.csv"), "w", encoding="utf-8", newline="") as f:
    f.write("Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n")
    f.write('Card Payment,Current,2026-02-01 10:00:00,2026-02-02 10:00:00,"Shop, with comma",-12.30,0.00,EUR,COMPLETED,100.00\n')
    f.write("Topup,Current,2026-02-01 09:00:00,2026-02-01 09:00:00,Top-up by *0000,50.00,0.00,EUR,COMPLETED,112.30\n")
    f.write("Card Payment,Current,2026-02-03 10:00:00,,Pending Shop,-5.00,0.00,EUR,PENDING,107.30\n")
print("ok")
