// Package fixtures generates the SYNTHETIC importer fixtures (port of tools/make_fixtures.py): bill codes, UBL invoices and
// PDFs, generic CSVs and the Revolut-style CSV, plus `embed`, which base64-encodes the bank files into the Dart file the
// integration tests use. Nothing here is real data. The JSON, XML and CSV files are byte-identical to what the Python script
// wrote (CPython's random is reproduced by internal/pyrand); the PDFs are written with Go's zlib, so their compressed streams
// differ while the decoded content is the same (TestPDFsMatchOldContent).
//
// The two Excel files (pbz_synthetic.xls, revolut_synthetic.xlsx) were made with xlwt/openpyxl, which this tool does not
// have: they are frozen, committed as they are, and not written any more.
package fixtures

import (
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// FrozenNote is the one line printed when the Excel files are not written.
const FrozenNote = "pbz_synthetic.xls and revolut_synthetic.xlsx are frozen (committed as they are), not generated"

// Run is `fixtures <out_dir> [all|banks|bills|generic]`. It returns the exit code (2 = usage).
func Run(out, errw io.Writer, args []string) int {
	if len(args) < 1 || len(args) > 2 {
		fmt.Fprintln(errw, "usage: fixtures <out_dir> [all|banks|bills|generic]   |   fixtures embed")
		return 2
	}
	dir, what := args[0], "all"
	if len(args) == 2 {
		what = args[1]
	}
	switch what {
	case "all", "banks", "bills", "generic":
	default:
		fmt.Fprintf(errw, "fixtures: unknown set %q (all|banks|bills|generic)\n", what)
		return 2
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintf(errw, "fixtures: %v\n", err)
		return 1
	}
	step := func(err error) bool {
		if err != nil {
			fmt.Fprintf(errw, "fixtures: %v\n", err)
			return false
		}
		return true
	}
	if what == "all" || what == "bills" {
		if !step(Bills(filepath.Join(dir, "bills"))) {
			return 1
		}
	}
	if what == "bills" {
		fmt.Fprintln(out, "ok")
		return 0
	}
	if what == "all" || what == "generic" {
		if !step(Generic(filepath.Join(dir, "generic"))) {
			return 1
		}
	}
	if what == "generic" {
		fmt.Fprintln(out, "ok")
		return 0
	}
	if !step(RevolutCSV(dir)) {
		return 1
	}
	fmt.Fprintln(out, FrozenNote)
	fmt.Fprintln(out, "ok")
	return 0
}

// cp1250 maps the non-ASCII characters of the generic fixtures (Croatian letters) to Windows-1250 bytes.
var cp1250 = map[rune]byte{'č': 0xE8, 'ć': 0xE6, 'š': 0x9A, 'ž': 0x9E, 'đ': 0xF0, 'Č': 0xC8, 'Ć': 0xC6, 'Š': 0x8A, 'Ž': 0x8E, 'Đ': 0xD0}

func encodeCP1250(s string) []byte {
	var out []byte
	for _, r := range s {
		switch b, ok := cp1250[r]; {
		case ok:
			out = append(out, b)
		case r < 0x80:
			out = append(out, byte(r))
		default:
			panic(fmt.Sprintf("fixtures: no Windows-1250 byte for %q", r))
		}
	}
	return out
}

// Generic writes the CSV shapes no bank profile knows (P12: import by a column mapping; made-up shops and amounts):
// encodings, delimiters, header rows and amount styles for the mapping tests.
func Generic(d string) error {
	if err := os.MkdirAll(d, 0o755); err != nil {
		return err
	}
	put := func(name string, data []byte, bom bool) error {
		if bom {
			data = append([]byte("\xef\xbb\xbf"), data...)
		}
		return os.WriteFile(filepath.Join(d, name), data, 0o644)
	}
	join := func(sep string, lines ...string) string {
		s := ""
		for i, l := range lines {
			if i > 0 {
				s += sep
			}
			s += l
		}
		return s
	}
	// UTF-8 with a BOM, `;`, header on row 1, one signed amount column with decimal comma and thousands dots, a quoted field
	// with the delimiter inside.
	if err := put("bom_semicolon.csv", []byte(join("\r\n",
		"Datum;Opis;Iznos;Valuta",
		`05.01.2026;"Kupnja; SYNTH DUCAN";-12,30;EUR`,
		"06.01.2026;Uplata SYNTH;1.234,56;EUR",
		"07.01.2026;SYNTH KAVANA;-3,5;EUR",
		"08.01.2026;SYNTH KAVANA;-3,50;EUR")+"\r\n"), true); err != nil {
		return err
	}
	// Windows-1250, `;`, two title lines (header on row 3), debit/credit columns, č ć š ž đ, a ragged last row.
	if err := put("hr_cp1250.csv", encodeCP1250(join("\r\n",
		"Izvod po računu;;;;;",
		"Račun: HR00 0000 0000 0000 0000 0;;;;;",
		"Datum knjiženja;Opis plaćanja;Primatelj;Duguje;Potražuje;Valuta",
		"10.01.2026.;Kupnja čokolade;SYNTH ĆEVAPI ŠĐŽ d.o.o.;12,30;;EUR",
		"11.01.2026.;Uplata plaće;SYNTH POSLODAVAC;;1.500,00;EUR",
		"12.01.2026.;Naknada;;0,33;0,00;EUR",
		"13.01.2026.;Kupnja")+"\r\n"), false); err != nil {
		return err
	}
	// UTF-8, `,`, ISO dates with a time, point decimals, quoted commas, twin rows (the occurrence counter).
	if err := put("en_comma.csv", []byte(join("\n",
		"Date,Description,Amount,Currency",
		`2026-02-01 10:00:00,"Shop, with comma",-12.30,EUR`,
		"2026-02-01 11:00:00,Synth Coffee,-2.50,EUR",
		"2026-02-01 11:00:00,Synth Coffee,-2.50,EUR",
		`2026-02-02T09:00:00,Synth Salary,"2,500.00",EUR`)+"\n"), false); err != nil {
		return err
	}
	// Tab, dd/mm/yyyy, spending shown as positive (negate), point style with thousands commas, a skip column.
	return put("positive_tab.csv", []byte(join("\n",
		"Booking date\tPayee\tDetails\tAmount\tStatus",
		"03/03/2026\tSynth Market\tCard\t1,234.56\tBOOKED",
		"04/03/2026\tSynth Refund\tCard\t-20.00\tBOOKED",
		"05/03/2026\tSynth Pending\tCard\t9.99\t")+"\n"), false)
}

// RevolutCSV writes revolut_synthetic.csv into dir.
func RevolutCSV(dir string) error {
	text := "Type,Product,Started Date,Completed Date,Description,Amount,Fee,Currency,State,Balance\n" +
		`Card Payment,Current,2026-02-01 10:00:00,2026-02-02 10:00:00,"Shop, with comma",-12.30,0.00,EUR,COMPLETED,100.00` + "\n" +
		"Topup,Current,2026-02-01 09:00:00,2026-02-01 09:00:00,Top-up by *0000,50.00,0.00,EUR,COMPLETED,112.30\n" +
		"Card Payment,Current,2026-02-03 10:00:00,,Pending Shop,-5.00,0.00,EUR,PENDING,107.30\n"
	return os.WriteFile(filepath.Join(dir, "revolut_synthetic.csv"), []byte(text), 0o644)
}

// Embed files, in the order of app/integration_test/support/fixtures.dart.
var embedFiles = []struct{ file, doc, getter, name string }{
	{"pbz_synthetic.xls", "pbz_synthetic.xls", "pbzXls", "_pbzXls"},
	{"revolut_synthetic.xlsx", "revolut_synthetic.xlsx", "revolutXlsx", "_revolutXlsx"},
	{"revolut_synthetic.csv", "revolut_synthetic.csv", "revolutCsvFile", "_revolutCsvFile"},
}

// EmbedPaths are the fixtures folder and the Dart file, relative to the repository.
const (
	FixturesDir = "packages/wallet_importer/test/fixtures"
	EmbedFile   = "app/integration_test/support/fixtures.dart"
)

// Embed returns the text of app/integration_test/support/fixtures.dart for the bank files in fixturesDir (a device has no
// access to the repo, so the integration tests carry them as base64).
func Embed(fixturesDir string) (string, error) {
	s := "// GENERATED from packages/wallet_importer/test/fixtures (SYNTHETIC files from tools/make_fixtures.py), base64.\n" +
		"// A device has no access to the repo, so the importer fixtures are embedded here.\n" +
		"// app/test/fixtures_sync_test.dart fails when they drift: then base64-encode the files again.\n" +
		"import 'dart:convert';\nimport 'dart:typed_data';\n"
	for _, f := range embedFiles {
		data, err := os.ReadFile(filepath.Join(fixturesDir, f.file))
		if err != nil {
			return "", err
		}
		s += fmt.Sprintf("\n/// %s\nUint8List get %s => base64Decode(%s);\nconst %s =\n    '%s';\n",
			f.doc, f.getter, f.name, f.name, base64.StdEncoding.EncodeToString(data))
	}
	return s, nil
}

// RunEmbed is `fixtures embed`: writes the Dart file under root.
func RunEmbed(root string, out, errw io.Writer) int {
	text, err := Embed(filepath.Join(root, FixturesDir))
	if err != nil {
		fmt.Fprintf(errw, "fixtures embed: %v\n", err)
		return 1
	}
	if err := os.WriteFile(filepath.Join(root, EmbedFile), []byte(text), 0o644); err != nil {
		fmt.Fprintf(errw, "fixtures embed: %v\n", err)
		return 1
	}
	fmt.Fprintf(out, "wrote %s\n", EmbedFile)
	return 0
}
