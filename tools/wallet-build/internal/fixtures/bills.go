package fixtures

import (
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"

	"wallet-build/internal/pyrand"
	"wallet-build/internal/report"
)

// All of it is SYNTHETIC: fictional payees, made-up bank codes 999xxxx, random JIR/ZKI from seed 2026.

// hrIBAN is a Croatian IBAN with a valid mod-97 checksum for a made-up bank code and account.
func hrIBAN(bank7, account10 string) string {
	bban := bank7 + account10
	n, _ := new(big.Int).SetString(bban+"172700", 10)
	n.Mod(n, big.NewInt(97))
	return fmt.Sprintf("HR%02d%s", 98-n.Int64(), bban)
}

// grouped is the IBAN in blocks of four.
func grouped(iban string) string {
	var parts []string
	for i := 0; i < len(iban); i += 4 {
		parts = append(parts, iban[i:min(i+4, len(iban))])
	}
	return strings.Join(parts, " ")
}

func obj(kv ...any) report.Obj {
	o := report.Obj{}
	for i := 0; i < len(kv); i += 2 {
		o = append(o, report.KV{K: kv[i].(string), V: kv[i+1]})
	}
	return o
}

func hex4(n int) string { return fmt.Sprintf("%04X", n) }

func writeText(path, text string) error { return os.WriteFile(path, []byte(text), 0o644) }

func writeJSON(path string, v any) error {
	return writeText(path, report.Dumper{Indent: 1}.Dump(v))
}

// Bills writes <d>/: codes.json, pdfs.json, the UBL invoices and the four PDFs.
func Bills(d string) error {
	if err := os.MkdirAll(d, 0o755); err != nil {
		return err
	}
	br := pyrand.New(2026)
	jir := func() string { return pyrand.UUID4(br.GetRandBits(128)) }
	zki := func() string { return pyrand.Hex32(br.GetRandBits(128)) }
	ibanA := hrIBAN("9990001", "1000000017")
	ibanB := hrIBAN("9990002", "3200000458")
	ibanC := hrIBAN("9990003", "5500000123")
	var chk int
	fmt.Sscanf(ibanA[2:4], "%d", &chk)
	badIBAN := ibanA[:2] + fmt.Sprintf("%02d", chk%97+1) + ibanA[4:]

	// fiscal receipt QR payloads and HUB-3 barcode texts, with what the readers must return
	j1, j2, z1 := jir(), jir(), zki() // call order matters: the generator is shared
	qr := []any{
		obj("payload", "https://porezna.gov.hr/rn?jir="+j1+"&datv=20260314_1532&izn=1250",
			"bill", obj("externalId", "jir:"+j1, "date", "2026-03-14", "total", 1250)),
		obj("payload", "https://porezna.gov.hr/rn?zki="+z1+"&datv=20260401_0905&izn=7,99",
			"bill", obj("externalId", "zki:"+z1, "date", "2026-04-01", "total", 799)),
		obj("payload", "https://porezna.gov.hr/rn?jir="+strings.ToUpper(j2)+"&datv=20261231_2359&izn=100.5",
			"bill", obj("externalId", "jir:"+j2, "date", "2026-12-31", "total", 10050)),
	}
	payer := []string{"Pero Probni", "Probna ulica 1", "10000 Grad"}
	join := func(sep string, head []string, tail ...string) string {
		all := append(append(append([]string{}, head...), payer...), tail...)
		return strings.Join(all, sep)
	}
	hub3 := []any{
		obj("payload", join("\n", []string{"HRVHUB30", "EUR", "000000000002550"},
			"Primjer Energija d.o.o.", "Izmišljena 5", "21000 Mjesto", ibanA, "HR01", "2026-0042-1", "COST", "Pretplata 10/2026"),
			"bill", obj("externalId", "hub3:"+ibanA+":HR01 2026-0042-1:2550:PRETPLATA 10/2026", "payee", "Primjer Energija d.o.o.", "iban", ibanA,
				"reference", "HR01 2026-0042-1", "description", "Pretplata 10/2026", "total", 2550, "currency", "EUR", "unsure", 0)),
		obj("payload", join("\r\n", []string{"HRVHUB30", "EUR", "000000000012000"},
			"Primjer Voda d.o.o.", "", "", ibanB, "HR99", "", "WTER", "")+"\r\n\r\n",
			"bill", obj("externalId", "hub3:"+ibanB+":HR99:12000:", "payee", "Primjer Voda d.o.o.", "iban", ibanB, "reference", "HR99",
				"description", nil, "total", 12000, "currency", "EUR", "unsure", 0)),
		obj("payload", join("\n", []string{"HRVHUB30", "EUR", "000000000000999"},
			"Primjer Klub", "Ulica 2", "31000 Mjesto", badIBAN, "HR00", "123", "OTHR", "Članarina"),
			"bill", obj("externalId", nil, "payee", "Primjer Klub", "iban", nil, "reference", "HR00 123", "description", "Članarina",
				"total", 999, "currency", "EUR", "unsure", 1)),
	}
	if err := writeJSON(filepath.Join(d, "codes.json"),
		obj("qr", qr, "hub3", hub3, "payer", payer, "ibans", []string{ibanA, ibanB, ibanC}, "badIban", badIBAN)); err != nil {
		return err
	}

	// UBL 2.1 invoices (EN 16931, HR CIUS)
	ns := `xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2" ` +
		`xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2" ` +
		`xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2" ` +
		`xmlns:ext="urn:oasis:names:specification:ubl:schema:xsd:CommonExtensionComponents-2" ` +
		`xmlns:hrextac="urn:mfin.gov.hr:schema:xsd:HRExtensionAggregateComponents-1"`
	line := func(i int, name, qty, unit, amount string) string {
		return fmt.Sprintf(`<cac:InvoiceLine><cbc:ID>%d</cbc:ID><cbc:InvoicedQuantity unitCode="%s">%s</cbc:InvoicedQuantity>`+
			`<cbc:LineExtensionAmount currencyID="EUR">%s</cbc:LineExtensionAmount><cac:Item><cbc:Name>%s</cbc:Name>`+
			`<cac:ClassifiedTaxCategory><cbc:ID>S</cbc:ID><cbc:Percent>25</cbc:Percent></cac:ClassifiedTaxCategory></cac:Item>`+
			`<cac:Price><cbc:PriceAmount currencyID="EUR">%s</cbc:PriceAmount></cac:Price></cac:InvoiceLine>`+"\n",
			i, unit, qty, amount, name, amount)
	}
	cius := "<cbc:CustomizationID>urn:cen.eu:en16931:2017#compliant#urn:mfin.gov.hr:cius-2025:1.0</cbc:CustomizationID>\n"
	inv1 := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>`+"\n"+`<Invoice %s>`+"\n"+
		`<ext:UBLExtensions><ext:UBLExtension><ext:ExtensionContent><hrextac:HRFISK20Data>`+
		`<hrextac:HRObracunPDVPoNaplati>false</hrextac:HRObracunPDVPoNaplati></hrextac:HRFISK20Data>`+
		`</ext:ExtensionContent></ext:UBLExtension></ext:UBLExtensions>`+"\n%s"+
		`<cbc:ProfileID>P1</cbc:ProfileID><cbc:ID>R-2026-0815</cbc:ID><cbc:IssueDate>2026-10-01</cbc:IssueDate>`+
		`<cbc:DueDate>2026-10-31</cbc:DueDate><cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>`+
		`<cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>`+"\n"+
		`<cac:AccountingSupplierParty><cac:Party><cbc:EndpointID schemeID="9934">00000000001</cbc:EndpointID>`+
		`<cac:PartyName><cbc:Name>Primjer Telekom d.o.o.</cbc:Name></cac:PartyName>`+
		`<cac:PostalAddress><cbc:StreetName>Izmišljena 9</cbc:StreetName><cbc:CityName>Mjesto</cbc:CityName>`+
		`<cac:Country><cbc:IdentificationCode>HR</cbc:IdentificationCode></cac:Country></cac:PostalAddress>`+
		`<cac:PartyTaxScheme><cbc:CompanyID>HR00000000001</cbc:CompanyID><cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme>`+
		`</cac:PartyTaxScheme><cac:PartyLegalEntity><cbc:RegistrationName>Primjer Telekom d.o.o.</cbc:RegistrationName>`+
		`</cac:PartyLegalEntity></cac:Party></cac:AccountingSupplierParty>`+"\n"+
		`<cac:AccountingCustomerParty><cac:Party><cac:PartyName><cbc:Name>Pero Probni</cbc:Name></cac:PartyName>`+
		`</cac:Party></cac:AccountingCustomerParty>`+"\n"+
		`<cac:PaymentMeans><cbc:PaymentMeansCode>30</cbc:PaymentMeansCode><cbc:PaymentID>HR01 2026-0815</cbc:PaymentID>`+
		`<cac:PayeeFinancialAccount><cbc:ID>%s</cbc:ID></cac:PayeeFinancialAccount></cac:PaymentMeans>`+"\n"+
		`<cac:TaxTotal><cbc:TaxAmount currencyID="EUR">4.70</cbc:TaxAmount></cac:TaxTotal>`+"\n"+
		`<cac:LegalMonetaryTotal><cbc:LineExtensionAmount currencyID="EUR">18.80</cbc:LineExtensionAmount>`+
		`<cbc:TaxExclusiveAmount currencyID="EUR">18.80</cbc:TaxExclusiveAmount>`+
		`<cbc:TaxInclusiveAmount currencyID="EUR">23.50</cbc:TaxInclusiveAmount>`+
		`<cbc:PayableAmount currencyID="EUR">23.50</cbc:PayableAmount></cac:LegalMonetaryTotal>`+"\n",
		ns, cius, ibanC) +
		line(1, "Mjesečna pretplata", "1", "C62", "15.00") +
		line(2, "Dodatni podatkovni paket", "2", "C62", "3.80") +
		"</Invoice>\n"
	inv2 := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>`+"\n"+`<Invoice %s>`+"\n%s"+
		`<cbc:ID>77/1/1</cbc:ID><cbc:IssueDate>2026-09-05</cbc:IssueDate><cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>`+"\n"+
		`<cac:AccountingSupplierParty><cac:Party><cac:PartyLegalEntity><cbc:RegistrationName>Primjer Servis obrt`+
		`</cbc:RegistrationName></cac:PartyLegalEntity></cac:Party></cac:AccountingSupplierParty>`+"\n"+
		`<cac:PaymentMeans><cbc:PaymentMeansCode>58</cbc:PaymentMeansCode><cbc:PaymentDueDate>2026-09-20</cbc:PaymentDueDate>`+
		`<cbc:PaymentID>HR00 77-1-1</cbc:PaymentID>`+
		`<cac:PayeeFinancialAccount><cbc:ID>%s</cbc:ID></cac:PayeeFinancialAccount></cac:PaymentMeans>`+"\n"+
		`<cac:LegalMonetaryTotal><cbc:PayableAmount currencyID="EUR">1234.500</cbc:PayableAmount></cac:LegalMonetaryTotal>`+"\n",
		ns, cius, grouped(ibanB)) +
		line(1, "Servis kotla", "1", "C62", "1000.00") +
		line(2, "Brtva", "1,5", "H87", "234.50") +
		line(3, "Sitni materijal", "3", "C62", "0.00") +
		"</Invoice>\n"
	for _, f := range []struct{ name, text string }{{"invoice_telekom.xml", inv1}, {"invoice_servis.xml", inv2}} {
		if err := writeText(filepath.Join(d, f.name), f.text); err != nil {
			return err
		}
	}

	// PDFs. 1. uncompressed, Helvetica WinAnsi + /Differences, two pages through a nested page tree (the first page has the
	// higher object numbers), an inline image to skip
	jirPDF := jir()
	p1 := []string{"Prodavatelj: Primjer Usluge d.o.o.", "Kupac: Pero Probni, Probna ulica 1", "RAČUN br. 2026-0042",
		"Datum računa: 3.10.2026.", "Rok plaćanja: 18.10.2026.", "IBAN: " + grouped(ibanA), "Poziv na broj: HR01 2026-0042",
		"Opis: Održavanje – listopad, šifra Ž-7", "Ukupno bez PDV-a: 20,00 EUR", "PDV 25%: 5,00 EUR"}
	c1 := append([]byte("BT /F1 10 Tf 14 TL 50 800 Td "), pdfLiteral(win(p1[0]))...)
	c1 = append(c1, " Tj\n"...)
	for _, t := range p1[1:] {
		c1 = append(c1, "T* "...)
		c1 = append(c1, pdfLiteral(win(t))...)
		c1 = append(c1, " Tj\n"...)
	}
	c1 = append(c1, "0 -14 Td ["...)
	c1 = append(c1, pdfLiteral(win("Za platiti:"))...)
	c1 = append(c1, " -500 "...)
	c1 = append(c1, pdfLiteral(win("25,00 "))...)
	c1 = append(c1, " 20 "...)
	c1 = append(c1, pdfLiteral(win("€"))...)
	c1 = append(c1, "] TJ ET\n"...)
	c2 := []byte("BT /F1 10 Tf 12 TL 50 800 Td (Stranica 2/2) Tj (JIR: " + jirPDF + ") ' ET\n" +
		"q BI /W 2 /H 1 /BPC 8 /CS /G ID \x00\xff EI Q\n")
	font := "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding << /Type /Encoding /BaseEncoding /WinAnsiEncoding " +
		"/Differences [198 /Cacute 200 /Ccaron 208 /Dcroat 230 /cacute 232 /ccaron 240 /dcroat] >> >>"
	objs := []pdfObj{
		{1, []byte("<< /Type /Catalog /Pages 2 0 R >>")},
		{2, []byte("<< /Type /Pages /Kids [7 0 R 3 0 R] /Count 2 /Resources << /Font << /F1 6 0 R >> >> >>")},
		{3, []byte("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>")},
		{4, pdfStream("", c2, false)},
		{5, pdfStream("", c1, false)},
		{6, []byte(font)},
		{7, []byte("<< /Type /Pages /Parent 2 0 R /Kids [8 0 R] /Count 1 >>")},
		{8, []byte("<< /Type /Page /Parent 7 0 R /MediaBox [0 0 595 842] /Contents [5 0 R] >>")},
	}
	if err := os.WriteFile(filepath.Join(d, "bill_winansi.pdf"), pdfFile(objs, 1, ""), 0o644); err != nil {
		return err
	}

	// 2. FlateDecode, Type0 Identity-H font + ToUnicode (bfchar, bfrange, array bfrange), font dicts in an object stream,
	// an xref stream instead of a trailer
	gid := map[rune]int{}
	hr := "čćđšžČĆĐŠŽ"
	singles := " :.,-€/"
	for _, g := range []struct {
		base  int
		chars string
	}{{0x0100, "abcdefghijklmnopqrstuvwxyz"}, {0x0200, hr}, {0x0300, "ABCDEFGHIJKLMNOPQRSTUVWXYZ"}, {0x0400, "0123456789"}, {0x0001, singles}} {
		for i, ch := range []rune(g.chars) {
			gid[ch] = g.base + i
		}
	}
	hexs := func(s string) string {
		var sb strings.Builder
		sb.WriteByte('<')
		for _, ch := range s {
			sb.WriteString(hex4(gid[ch]))
		}
		sb.WriteByte('>')
		return sb.String()
	}
	var tu strings.Builder
	tu.WriteString("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CMapName /Synthetic-UCS def\n/CMapType 2 def\n" +
		"1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n")
	fmt.Fprintf(&tu, "%d beginbfchar\n", len([]rune(singles)))
	for _, ch := range singles {
		fmt.Fprintf(&tu, "<%s> <%s>\n", hex4(gid[ch]), hex4(int(ch)))
	}
	tu.WriteString("endbfchar\n3 beginbfrange\n<0100> <0119> <0061>\n<0300> <0319> <0041>\n<0200> <0209> [")
	var hrCodes []string
	for _, ch := range hr {
		hrCodes = append(hrCodes, "<"+hex4(int(ch))+">")
	}
	tu.WriteString(strings.Join(hrCodes, " "))
	tu.WriteString("]\nendbfrange\n1 beginbfrange\n<0400> <0409> <0030>\nendbfrange\nendcmap\n" +
		"CMapName currentdict /CMap defineresource pop\nend\nend\n")
	jirT0 := jir()
	zkiT0 := zki()
	lines0 := []string{"Izdavatelj: Primjer Trgovina j.d.o.o.", "Račun: 7/POS1/1", "Datum: 2026-09-14", "Čokolada 2 x 1,50 3,00", "Kava 1 x 9,34 9,34"}
	c3 := "BT /F1 11 Tf\n"
	y := 780
	for _, t := range lines0 {
		c3 += fmt.Sprintf("1 0 0 1 50 %d Tm %s Tj\n", y, hexs(t))
		y -= 15
	}
	c3 += fmt.Sprintf("1 0 0 1 50 %d Tm [%s -30 %s -400 %s -350 %s] TJ\n", y, hexs("Uk"), hexs("upno:"), hexs("12,34"), hexs("€"))
	y -= 15
	c3 += fmt.Sprintf("1 0 0 1 50 %d Tm %s Tj\n1 0 0 1 50 %d Tm %s Tj\nET\n", y, hexs("JIR: "+jirT0), y-15, hexs("ZKI: "+zkiT0))
	o6 := "<< /Type /Font /Subtype /Type0 /BaseFont /SyntheticSans /Encoding /Identity-H /DescendantFonts [7 0 R] /ToUnicode 8 0 R >>"
	o7 := "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /SyntheticSans " +
		"/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 500 >>"
	head := fmt.Sprintf("6 0 7 %d ", len(o6)+1)
	out, offs := pdfObjects([]pdfObj{
		{1, []byte("<< /Type /Catalog /Pages 2 0 R >>")},
		{2, []byte("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")},
		{3, []byte("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R >>")},
		{4, pdfStream("", []byte(c3), true)},
		{5, pdfStream(fmt.Sprintf("/Type /ObjStm /N 2 /First %d", len(head)), []byte(head+o6+" "+o7), true)},
		{8, pdfStream("", []byte(tu.String()), true)},
	})
	offs[9] = len(out)
	var rows []byte
	be := func(v, n int) []byte { // v.to_bytes(n, "big")
		b := make([]byte, n)
		for i := n - 1; i >= 0; i-- {
			b[i] = byte(v)
			v >>= 8
		}
		return b
	}
	for i := 0; i < 10; i++ {
		switch off, ok := offs[i]; {
		case ok:
			rows = append(append(append(rows, 1), be(off, 4)...), be(0, 2)...)
		case i == 6 || i == 7:
			rows = append(append(append(rows, 2), be(5, 4)...), be(i-6, 2)...)
		default:
			rows = append(append(append(rows, 0), be(0, 4)...), be(65535, 2)...)
		}
	}
	out = append(out, "9 0 obj\n"...)
	out = append(out, pdfStream("/Type /XRef /Size 10 /W [1 4 2] /Root 1 0 R", rows, true)...)
	out = append(out, "\nendobj\n"...)
	out = fmt.Appendf(out, "startxref\n%d\n%%%%EOF\n", offs[9])
	if err := os.WriteFile(filepath.Join(d, "receipt_type0.pdf"), out, 0o644); err != nil {
		return err
	}

	// 3. an encrypted stub: readable-looking text, but /Encrypt in the trailer
	zeros := strings.Repeat("00", 32)
	objs = []pdfObj{
		{1, []byte("<< /Type /Catalog /Pages 2 0 R >>")},
		{2, []byte("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")},
		{3, []byte("<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>")},
		{4, []byte("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")},
		{5, pdfStream("", []byte("BT /F1 10 Tf 50 800 Td (Za platiti: 1,00) Tj ET"), false)},
		{6, []byte("<< /Filter /Standard /V 1 /R 2 /O <" + zeros + "> /U <" + zeros + "> /P -4 >>")},
	}
	if err := os.WriteFile(filepath.Join(d, "encrypted_stub.pdf"), pdfFile(objs, 1, "/Encrypt 6 0 R /ID [<00> <00>] "), 0o644); err != nil {
		return err
	}

	// 4. a printed HUB-3 block (simple font with a 1-byte ToUnicode CMap, Flate content) followed by a due date
	hubLines := append(append([]string{"HRVHUB30", "EUR", "000000000004599"}, payer...),
		"Primjer Energija d.o.o.", "Izmišljena 5", "21000 Mjesto", ibanA, "HR01", "2026-1001-77", "ELEC", "Račun za struju 10/2026")
	one := []struct {
		ch rune
		b  byte
	}{{'č', 0x80}, {'ć', 0x81}, {'đ', 0x82}, {'š', 0x83}, {'ž', 0x84}, {'Č', 0x85}}
	enc1 := func(s string) []byte {
		var out []byte
		for _, r := range s {
			b := byte(r)
			for _, o := range one {
				if o.ch == r {
					b = o.b
				}
			}
			out = append(out, b)
		}
		return out
	}
	var cm strings.Builder
	cm.WriteString("/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n1 begincodespacerange\n<00> <FF>\nendcodespacerange\n" +
		"1 beginbfrange\n<20> <7E> <0020>\nendbfrange\n")
	fmt.Fprintf(&cm, "%d beginbfchar\n", len(one))
	for _, o := range one {
		fmt.Fprintf(&cm, "<%02X> <%04X>\n", o.b, int(o.ch))
	}
	cm.WriteString("endbfchar\nendcmap\nend\nend\n")
	c4 := []byte("BT /F1 9 Tf 11 TL 40 500 Td\n")
	for _, t := range hubLines {
		c4 = append(c4, pdfLiteral(enc1(t))...)
		c4 = append(c4, " Tj T*\n"...)
	}
	c4 = append(c4, pdfLiteral(enc1("Datum dospijeća: 30.11.2026."))...)
	c4 = append(c4, " Tj ET\n"...)
	objs = []pdfObj{
		{1, []byte("<< /Type /Catalog /Pages 2 0 R >>")},
		{2, []byte("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")},
		{3, []byte("<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>")},
		{4, []byte("<< /Type /Font /Subtype /TrueType /BaseFont /SyntheticMono /FirstChar 32 /LastChar 133 /ToUnicode 6 0 R >>")},
		{5, pdfStream("", c4, true)},
		{6, pdfStream("", []byte(cm.String()), false)},
	}
	if err := os.WriteFile(filepath.Join(d, "hub3_printed.pdf"), pdfFile(objs, 1, ""), 0o644); err != nil {
		return err
	}

	strs := func(a []string, more ...string) []any {
		var out []any
		for _, s := range append(append([]string{}, a...), more...) {
			out = append(out, s)
		}
		return out
	}
	return writeJSON(filepath.Join(d, "pdfs.json"), obj(
		"bill_winansi.pdf", obj("lines", strs(p1, "Za platiti: 25,00 €", "Stranica 2/2", "JIR: "+jirPDF), "jir", jirPDF, "iban", ibanA),
		"receipt_type0.pdf", obj("lines", strs(lines0, "Ukupno: 12,34 €", "JIR: "+jirT0, "ZKI: "+zkiT0), "jir", jirT0),
		"hub3_printed.pdf", obj("lines", strs(hubLines, "Datum dospijeća: 30.11.2026."), "iban", ibanA),
	))
}
