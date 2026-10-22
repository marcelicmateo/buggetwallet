"""Generate SYNTHETIC bank export fixtures for importer tests. No real data.

PBZ-style .xls (BIFF8) with enough distinct strings to force SST CONTINUE records,
Revolut-style .xlsx with date cells and mojibake text, and a Revolut-style CSV.
Bills (`<out>/bills/`, no extra modules needed: `... fixtures bills`): fiscal QR and HUB-3 payloads, UBL e-invoices, small PDFs.
Usage: python3 tools/make_fixtures.py packages/wallet_importer/test/fixtures [all|banks|bills]
"""
import sys, os, datetime, random, json, uuid, zlib

out = sys.argv[1]
what = sys.argv[2] if len(sys.argv) > 2 else "all"
os.makedirs(out, exist_ok=True)
rnd = random.Random(42)

# ---------- bills (all SYNTHETIC: fictional payees, made-up bank codes 999xxxx, random JIR/ZKI) ----------
def hr_iban(bank7, account10):
    """A Croatian IBAN with a valid mod-97 checksum for a made-up bank code and account."""
    bban = bank7 + account10
    return "HR%02d%s" % (98 - int(bban + "1727" + "00") % 97, bban)


def pdf_objects(objs):
    """Header + numbered objects; returns (bytes, offsets)."""
    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offs = {}
    for num, body in objs:
        offs[num] = len(out)
        out += b"%d 0 obj\n" % num + body + b"\nendobj\n"
    return out, offs


def pdf_file(objs, root, trailer_extra=b""):
    """A classic PDF: header, objects in the given order, xref table, trailer."""
    out, offs = pdf_objects(objs)
    xref = len(out)
    size = max(offs) + 1
    out += b"xref\n0 %d\n0000000000 65535 f \n" % size
    for i in range(1, size):
        out += (b"%010d 00000 n \n" % offs[i]) if i in offs else b"0000000000 65535 f \n"
    out += b"trailer\n<< /Size %d /Root %d 0 R %s>>\nstartxref\n%d\n%%%%EOF\n" % (size, root, trailer_extra, xref)
    return bytes(out)


def pdf_stream(d, data, flate=False):
    if flate:
        data = zlib.compress(data)
        d = d + b" /Filter /FlateDecode"
    return b"<< " + d + b" /Length %d >>\nstream\n" % len(data) + data + b"\nendstream"


def pdf_literal(bs):
    out = bytearray(b"(")
    for c in bs:
        if c in (0x28, 0x29, 0x5C):
            out += b"\\" + bytes([c])
        elif c >= 0x80 or c < 0x20:
            out += b"\\%03o" % c
        else:
            out.append(c)
    return bytes(out + b")")


# WinAnsi bytes, plus the /Differences of bill_winansi.pdf for č ć đ Č Ć Đ
WIN = {"€": 0x80, "Š": 0x8A, "Ž": 0x8E, "š": 0x9A, "ž": 0x9E, "–": 0x96, "Ć": 198, "Č": 200, "Đ": 208, "ć": 230, "č": 232, "đ": 240}


def win(s):
    return bytes(WIN.get(ch, ord(ch)) for ch in s)


def grouped(iban):
    return " ".join(iban[i:i + 4] for i in range(0, len(iban), 4))


def write_bills(d):
    os.makedirs(d, exist_ok=True)
    br = random.Random(2026)
    jir = lambda: str(uuid.UUID(int=br.getrandbits(128), version=4))
    zki = lambda: "%032x" % br.getrandbits(128)
    iban_a = hr_iban("9990001", "1000000017")
    iban_b = hr_iban("9990002", "3200000458")
    iban_c = hr_iban("9990003", "5500000123")
    bad_iban = iban_a[:2] + ("%02d" % (int(iban_a[2:4]) % 97 + 1)) + iban_a[4:]

    # --- fiscal receipt QR payloads and HUB-3 barcode texts, with what the readers must return ---
    j1, j2, z1 = jir(), jir(), zki()
    qr = [
        {"payload": "https://porezna.gov.hr/rn?jir=%s&datv=20260314_1532&izn=1250" % j1,
         "bill": {"externalId": "jir:" + j1, "date": "2026-03-14", "total": 1250}},
        {"payload": "https://porezna.gov.hr/rn?zki=%s&datv=20260401_0905&izn=7,99" % z1,
         "bill": {"externalId": "zki:" + z1, "date": "2026-04-01", "total": 799}},
        {"payload": "https://porezna.gov.hr/rn?jir=%s&datv=20261231_2359&izn=100.5" % j2.upper(),
         "bill": {"externalId": "jir:" + j2, "date": "2026-12-31", "total": 10050}},
    ]
    payer = ["Pero Probni", "Probna ulica 1", "10000 Grad"]
    hub3 = [
        {"payload": "\n".join(["HRVHUB30", "EUR", "000000000002550"] + payer + [
            "Primjer Energija d.o.o.", "Izmišljena 5", "21000 Mjesto", iban_a, "HR01", "2026-0042-1", "COST", "Pretplata 10/2026"]),
         "bill": {"externalId": "hub3:%s:HR01 2026-0042-1:2550:PRETPLATA 10/2026" % iban_a, "payee": "Primjer Energija d.o.o.", "iban": iban_a,
                  "reference": "HR01 2026-0042-1", "description": "Pretplata 10/2026", "total": 2550, "currency": "EUR", "unsure": 0}},
        {"payload": "\r\n".join(["HRVHUB30", "EUR", "000000000012000"] + payer + [
            "Primjer Voda d.o.o.", "", "", iban_b, "HR99", "", "WTER", ""]) + "\r\n\r\n",
         "bill": {"externalId": "hub3:%s:HR99:12000:" % iban_b, "payee": "Primjer Voda d.o.o.", "iban": iban_b, "reference": "HR99",
                  "description": None, "total": 12000, "currency": "EUR", "unsure": 0}},
        {"payload": "\n".join(["HRVHUB30", "EUR", "000000000000999"] + payer + [
            "Primjer Klub", "Ulica 2", "31000 Mjesto", bad_iban, "HR00", "123", "OTHR", "Članarina"]),
         "bill": {"externalId": None, "payee": "Primjer Klub", "iban": None, "reference": "HR00 123", "description": "Članarina",
                  "total": 999, "currency": "EUR", "unsure": 1}},
    ]
    with open(os.path.join(d, "codes.json"), "w", encoding="utf-8") as f:
        json.dump({"qr": qr, "hub3": hub3, "payer": payer, "ibans": [iban_a, iban_b, iban_c], "badIban": bad_iban}, f,
                  ensure_ascii=False, indent=1)

    # --- UBL 2.1 invoices (EN 16931, HR CIUS) ---
    ns = ('xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2" '
          'xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2" '
          'xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2" '
          'xmlns:ext="urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2" '
          'xmlns:hrextac="urn:mfin.gov.hr:schema:xsd:HRExtensionAggregateComponents-1"')

    def line(i, name, qty, unit, amount):
        return ('<cac:InvoiceLine><cbc:ID>%d</cbc:ID><cbc:InvoicedQuantity unitCode="%s">%s</cbc:InvoicedQuantity>'
                '<cbc:LineExtensionAmount currencyID="EUR">%s</cbc:LineExtensionAmount><cac:Item><cbc:Name>%s</cbc:Name>'
                '<cac:ClassifiedTaxCategory><cbc:ID>S</cbc:ID><cbc:Percent>25</cbc:Percent></cac:ClassifiedTaxCategory></cac:Item>'
                '<cac:Price><cbc:PriceAmount currencyID="EUR">%s</cbc:PriceAmount></cac:Price></cac:InvoiceLine>\n'
                % (i, unit, qty, amount, name, amount))

    cius = '<cbc:CustomizationID>urn:cen.eu:en16931:2017#compliant#urn:mfin.gov.hr:cius-2025:1.0</cbc:CustomizationID>\n'
    inv1 = ('<?xml version="1.0" encoding="UTF-8"?>\n<Invoice %s>\n'
            '<ext:UBLExtensions><ext:UBLExtension><ext:ExtensionContent><hrextac:HRFISK20Data>'
            '<hrextac:HRObracunPDVPoNaplati>false</hrextac:HRObracunPDVPoNaplati></hrextac:HRFISK20Data>'
            '</ext:ExtensionContent></ext:UBLExtension></ext:UBLExtensions>\n%s'
            '<cbc:ProfileID>P1</cbc:ProfileID><cbc:ID>R-2026-0815</cbc:ID><cbc:IssueDate>2026-10-01</cbc:IssueDate>'
            '<cbc:DueDate>2026-10-31</cbc:DueDate><cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>'
            '<cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>\n'
            '<cac:AccountingSupplierParty><cac:Party><cbc:EndpointID schemeID="9934">00000000001</cbc:EndpointID>'
            '<cac:PartyName><cbc:Name>Primjer Telekom d.o.o.</cbc:Name></cac:PartyName>'
            '<cac:PostalAddress><cbc:StreetName>Izmišljena 9</cbc:StreetName><cbc:CityName>Mjesto</cbc:CityName>'
            '<cac:Country><cbc:IdentificationCode>HR</cbc:IdentificationCode></cac:Country></cac:PostalAddress>'
            '<cac:PartyTaxScheme><cbc:CompanyID>HR00000000001</cbc:CompanyID><cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>'
            '</cac:PartyTaxScheme><cac:PartyLegalEntity><cbc:RegistrationName>Primjer Telekom d.o.o.</cbc:RegistrationName>'
            '</cac:PartyLegalEntity></cac:Party></cac:AccountingSupplierParty>\n'
            '<cac:AccountingCustomerParty><cac:Party><cac:PartyName><cbc:Name>Pero Probni</cbc:Name></cac:PartyName>'
            '</cac:Party></cac:AccountingCustomerParty>\n'
            '<cac:PaymentMeans><cbc:PaymentMeansCode>30</cbc:PaymentMeansCode><cbc:PaymentID>HR01 2026-0815</cbc:PaymentID>'
            '<cac:PayeeFinancialAccount><cbc:ID>%s</cbc:ID></cac:PayeeFinancialAccount></cac:PaymentMeans>\n'
            '<cac:TaxTotal><cbc:TaxAmount currencyID="EUR">4.70</cbc:TaxAmount></cac:TaxTotal>\n'
            '<cac:LegalMonetaryTotal><cbc:LineExtensionAmount currencyID="EUR">18.80</cbc:LineExtensionAmount>'
            '<cbc:TaxExclusiveAmount currencyID="EUR">18.80</cbc:TaxExclusiveAmount>'
            '<cbc:TaxInclusiveAmount currencyID="EUR">23.50</cbc:TaxInclusiveAmount>'
            '<cbc:PayableAmount currencyID="EUR">23.50</cbc:PayableAmount></cac:LegalMonetaryTotal>\n'
            % (ns, cius, iban_c)
            + line(1, "Mjesečna pretplata", "1", "C62", "15.00")
            + line(2, "Dodatni podatkovni paket", "2", "C62", "3.80")
            + "</Invoice>\n")
    inv2 = ('<?xml version="1.0" encoding="UTF-8"?>\n<Invoice %s>\n%s'
            '<cbc:ID>77/1/1</cbc:ID><cbc:IssueDate>2026-09-05</cbc:IssueDate><cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>\n'
            '<cac:AccountingSupplierParty><cac:Party><cac:PartyLegalEntity><cbc:RegistrationName>Primjer Servis obrt'
            '</cbc:RegistrationName></cac:PartyLegalEntity></cac:Party></cac:AccountingSupplierParty>\n'
            '<cac:PaymentMeans><cbc:PaymentMeansCode>58</cbc:PaymentMeansCode><cbc:PaymentDueDate>2026-09-20</cbc:PaymentDueDate>'
            '<cbc:PaymentID>HR00 77-1-1</cbc:PaymentID>'
            '<cac:PayeeFinancialAccount><cbc:ID>%s</cbc:ID></cac:PayeeFinancialAccount></cac:PaymentMeans>\n'
            '<cac:LegalMonetaryTotal><cbc:PayableAmount currencyID="EUR">1234.500</cbc:PayableAmount></cac:LegalMonetaryTotal>\n'
            % (ns, cius, grouped(iban_b))
            + line(1, "Servis kotla", "1", "C62", "1000.00")
            + line(2, "Brtva", "1,5", "H87", "234.50")
            + line(3, "Sitni materijal", "3", "C62", "0.00")
            + "</Invoice>\n")
    for name, text in (("invoice_telekom.xml", inv1), ("invoice_servis.xml", inv2)):
        with open(os.path.join(d, name), "w", encoding="utf-8") as f:
            f.write(text)

    # --- PDFs ---
    # 1. uncompressed, Helvetica WinAnsi + /Differences, two pages through a nested page tree (the first page has the
    #    higher object numbers), an inline image to skip
    jir_pdf = jir()
    p1 = ["Prodavatelj: Primjer Usluge d.o.o.", "Kupac: Pero Probni, Probna ulica 1", "RAČUN br. 2026-0042",
          "Datum računa: 3.10.2026.", "Rok plaćanja: 18.10.2026.", "IBAN: " + grouped(iban_a), "Poziv na broj: HR01 2026-0042",
          "Opis: Održavanje – listopad, šifra Ž-7", "Ukupno bez PDV-a: 20,00 EUR", "PDV 25%: 5,00 EUR"]
    c1 = b"BT /F1 10 Tf 14 TL 50 800 Td " + pdf_literal(win(p1[0])) + b" Tj\n"
    for t in p1[1:]:
        c1 += b"T* " + pdf_literal(win(t)) + b" Tj\n"
    c1 += (b"0 -14 Td [" + pdf_literal(win("Za platiti:")) + b" -500 " + pdf_literal(win("25,00 ")) + b" 20 "
           + pdf_literal(win("€")) + b"] TJ ET\n")
    c2 = (b"BT /F1 10 Tf 12 TL 50 800 Td (Stranica 2/2) Tj (JIR: " + jir_pdf.encode() + b") ' ET\n"
          b"q BI /W 2 /H 1 /BPC 8 /CS /G ID \x00\xff EI Q\n")
    font = (b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding "
            b"/Differences [198 /Cacute 200 /Ccaron 208 /Dcroat 230 /cacute 232 /ccaron 240 /dcroat] >> >>")
    objs = [
        (1, b"<< /Type /Catalog /Pages 2 0 R >>"),
        (2, b"<< /Type /Pages /Kids [7 0 R 3 0 R] /Count 2 /Resources << /Font << /F1 6 0 R >> >> >>"),
        (3, b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>"),
        (4, pdf_stream(b"", c2)),
        (5, pdf_stream(b"", c1)),
        (6, font),
        (7, b"<< /Type /Pages /Parent 2 0 R /Kids [8 0 R] /Count 1 >>"),
        (8, b"<< /Type /Page /Parent 7 0 R /MediaBox [0 0 595 842] /Contents [5 0 R] >>"),
    ]
    with open(os.path.join(d, "bill_winansi.pdf"), "wb") as f:
        f.write(pdf_file(objs, 1))

    # 2. FlateDecode, Type0 Identity-H font + ToUnicode (bfchar, bfrange, array bfrange), font dicts in an object
    #    stream, an xref stream instead of a trailer
    gid = {}
    hr = "čćđšžČĆĐŠŽ"
    singles = " :.,-€/"
    for base, chars in ((0x0100, "abcdefghijklmnopqrstuvwxyz"), (0x0200, hr), (0x0300, "ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
                        (0x0400, "0123456789"), (0x0001, singles)):
        for i, ch in enumerate(chars):
            gid[ch] = base + i
    hexs = lambda s: b"<" + "".join("%04X" % gid[ch] for ch in s).encode() + b">"
    tounicode = (b"/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CMapName /Synthetic-UCS def\n/CMapType 2 def\n"
                 b"1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n%d beginbfchar\n" % len(singles)
                 + b"".join(b"<%04X> <%04X>\n" % (gid[ch], ord(ch)) for ch in singles) + b"endbfchar\n3 beginbfrange\n"
                 b"<0100> <0119> <0061>\n<0300> <0319> <0041>\n<0200> <0209> [" + b" ".join(b"<%04X>" % ord(ch) for ch in hr)
                 + b"]\nendbfrange\n1 beginbfrange\n<0400> <0409> <0030>\nendbfrange\nendcmap\n"
                 b"CMapName currentdict /CMap defineresource pop\nend\nend\n")
    jir_t0, zki_t0 = jir(), zki()
    lines0 = ["Izdavatelj: Primjer Trgovina j.d.o.o.", "Račun: 7/POS1/1", "Datum: 2026-09-14", "Čokolada 2 x 1,50 3,00",
              "Kava 1 x 9,34 9,34"]
    c3 = b"BT /F1 11 Tf\n"
    y = 780
    for t in lines0:
        c3 += b"1 0 0 1 50 %d Tm %s Tj\n" % (y, hexs(t))
        y -= 15
    c3 += b"1 0 0 1 50 %d Tm [%s -30 %s -400 %s -350 %s] TJ\n" % (y, hexs("Uk"), hexs("upno:"), hexs("12,34"), hexs("€"))
    y -= 15
    c3 += b"1 0 0 1 50 %d Tm %s Tj\n1 0 0 1 50 %d Tm %s Tj\nET\n" % (y, hexs("JIR: " + jir_t0), y - 15, hexs("ZKI: " + zki_t0))
    o6 = b"<< /Type /Font /Subtype /Type0 /BaseFont /SyntheticSans /Encoding /Identity-H /DescendantFonts [7 0 R] /ToUnicode 8 0 R >>"
    o7 = (b"<< /Type /Font /Subtype /CIDFontType2 /BaseFont /SyntheticSans "
          b"/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 500 >>")
    head = b"6 0 7 %d " % (len(o6) + 1)
    out, offs = pdf_objects([
        (1, b"<< /Type /Catalog /Pages 2 0 R >>"),
        (2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (3, b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R >>"),
        (4, pdf_stream(b"", c3, flate=True)),
        (5, pdf_stream(b"/Type /ObjStm /N 2 /First %d" % len(head), head + o6 + b" " + o7, flate=True)),
        (8, pdf_stream(b"", tounicode, flate=True)),
    ])
    offs[9] = len(out)
    rows = b""
    for i in range(10):
        if i in offs:
            rows += bytes([1]) + offs[i].to_bytes(4, "big") + (0).to_bytes(2, "big")
        elif i in (6, 7):
            rows += bytes([2]) + (5).to_bytes(4, "big") + (i - 6).to_bytes(2, "big")
        else:
            rows += bytes([0]) + (0).to_bytes(4, "big") + (65535).to_bytes(2, "big")
    out += b"9 0 obj\n" + pdf_stream(b"/Type /XRef /Size 10 /W [1 4 2] /Root 1 0 R", rows, flate=True) + b"\nendobj\n"
    out += b"startxref\n%d\n%%%%EOF\n" % offs[9]
    with open(os.path.join(d, "receipt_type0.pdf"), "wb") as f:
        f.write(bytes(out))

    # 3. an encrypted stub: readable-looking text, but /Encrypt in the trailer
    objs = [
        (1, b"<< /Type /Catalog /Pages 2 0 R >>"),
        (2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (3, b"<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"),
        (4, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        (5, pdf_stream(b"", b"BT /F1 10 Tf 50 800 Td (Za platiti: 1,00) Tj ET")),
        (6, b"<< /Filter /Standard /V 1 /R 2 /O <" + b"00" * 32 + b"> /U <" + b"00" * 32 + b"> /P -4 >>"),
    ]
    with open(os.path.join(d, "encrypted_stub.pdf"), "wb") as f:
        f.write(pdf_file(objs, 1, b"/Encrypt 6 0 R /ID [<00> <00>] "))

    # 4. a printed HUB-3 block (simple font with a 1-byte ToUnicode CMap, Flate content) followed by a due date
    hub_lines = ["HRVHUB30", "EUR", "000000000004599"] + payer + [
        "Primjer Energija d.o.o.", "Izmišljena 5", "21000 Mjesto", iban_a, "HR01", "2026-1001-77", "ELEC", "Račun za struju 10/2026"]
    one = {"č": 0x80, "ć": 0x81, "đ": 0x82, "š": 0x83, "ž": 0x84, "Č": 0x85}
    enc1 = lambda s: bytes(one.get(ch, ord(ch)) for ch in s)
    cmap1 = (b"/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n1 begincodespacerange\n<00> <FF>\nendcodespacerange\n"
             b"1 beginbfrange\n<20> <7E> <0020>\nendbfrange\n%d beginbfchar\n" % len(one)
             + b"".join(b"<%02X> <%04X>\n" % (v, ord(k)) for k, v in one.items()) + b"endbfchar\nendcmap\nend\nend\n")
    c4 = (b"BT /F1 9 Tf 11 TL 40 500 Td\n" + b"".join(pdf_literal(enc1(t)) + b" Tj T*\n" for t in hub_lines)
          + pdf_literal(enc1("Datum dospijeća: 30.11.2026.")) + b" Tj ET\n")
    objs = [
        (1, b"<< /Type /Catalog /Pages 2 0 R >>"),
        (2, b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
        (3, b"<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>"),
        (4, b"<< /Type /Font /Subtype /TrueType /BaseFont /SyntheticMono /FirstChar 32 /LastChar 133 /ToUnicode 6 0 R >>"),
        (5, pdf_stream(b"", c4, flate=True)),
        (6, pdf_stream(b"", cmap1)),
    ]
    with open(os.path.join(d, "hub3_printed.pdf"), "wb") as f:
        f.write(pdf_file(objs, 1))

    with open(os.path.join(d, "pdfs.json"), "w", encoding="utf-8") as f:
        json.dump({
            "bill_winansi.pdf": {"lines": p1 + ["Za platiti: 25,00 €", "Stranica 2/2", "JIR: " + jir_pdf], "jir": jir_pdf, "iban": iban_a},
            "receipt_type0.pdf": {"lines": lines0 + ["Ukupno: 12,34 €", "JIR: " + jir_t0, "ZKI: " + zki_t0], "jir": jir_t0},
            "hub3_printed.pdf": {"lines": hub_lines + ["Datum dospijeća: 30.11.2026."], "iban": iban_a},
        }, f, ensure_ascii=False, indent=1)


if what in ("all", "bills"):
    write_bills(os.path.join(out, "bills"))
if what == "bills":
    print("ok")
    sys.exit(0)

import xlwt, openpyxl

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
