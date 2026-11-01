// Package mutate is mutation testing for the pure Dart packages (port of tools/mutate.py; same operators, same sampling,
// same files and output lines). Per target file it lists simple one-token mutants and runs a seeded sample of them against
// the package tests, in a copy of the packages under dist/mutation/work (the tracked files are never touched).
package mutate

import (
	"math/big"
	"os"
	"regexp"
	"strings"
	"unicode"
)

// Mutant is one change: the rune range [Start, End) of the (newline-normalised) source becomes Text.
type Mutant struct {
	Line, Col  int // 1-based, in runes
	Start, End int
	Op         string
	Orig       string
	Mutant     string
	Text       string
}

type opPair struct{ old, new, name string }

// ops are the swaps on space-surrounded operators; the spaces keep generics (List<int>) and `=>` out.
var ops = []opPair{
	{" + ", " - ", "+ -> -"}, {" - ", " + ", "- -> +"}, {" * ", " ~/ ", "* -> ~/"}, {" ~/ ", " * ", "~/ -> *"},
	{" < ", " <= ", "< -> <="}, {" <= ", " < ", "<= -> <"}, {" > ", " >= ", "> -> >="}, {" >= ", " > ", ">= -> >"},
	{" == ", " != ", "== -> !="}, {" != ", " == ", "!= -> =="}, {" && ", " || ", "&& -> ||"}, {" || ", " && ", "|| -> &&"},
}

var defaults = map[string]string{"int": "0", "bool": "false", "double": "0.0", "String": "''"}

var reMember = regexp.MustCompile(`^\s*(?:static\s+)?(int|bool|double|String)\s+[\w.]+\s*(?:<[^>]*>)?\s*(?:\(|=>|\{|get\b)`)

func isWord(r rune) bool {
	return r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r) || unicode.IsNumber(r)
}

func isAlnum(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) || unicode.IsNumber(r) }

// startsWith: the patterns are ASCII, so bytes and runes line up.
func startsWith(s []rune, i int, p string) bool {
	if i < 0 || i+len(p) > len(s) {
		return false
	}
	for k := 0; k < len(p); k++ {
		if s[i+k] != rune(p[k]) {
			return false
		}
	}
	return true
}

func find(s []rune, p string, from int) int {
	for i := from; i+len(p) <= len(s); i++ {
		if startsWith(s, i, p) {
			return i
		}
	}
	return -1
}

// CodeMask is true for each rune that is code (not a comment, string, or string interpolation).
func CodeMask(src []rune) []bool {
	n := len(src)
	mask := make([]bool, n)
	for i := range mask {
		mask[i] = true
	}
	clear := func(a, b int) {
		for k := a; k < b && k < n; k++ {
			mask[k] = false
		}
	}
	i := 0
	for i < n {
		c := src[i]
		switch {
		case startsWith(src, i, "//"):
			j := find(src, "\n", i)
			if j < 0 {
				j = n
			}
			clear(i, j)
			i = j
		case startsWith(src, i, "/*"):
			j := find(src, "*/", i+2)
			if j < 0 {
				j = n
			} else {
				j += 2
			}
			clear(i, j)
			i = j
		case c == '\'' || c == '"' || (c == 'r' && i+1 < n && (src[i+1] == '\'' || src[i+1] == '"') && !(i > 0 && (isAlnum(src[i-1]) || src[i-1] == '_'))):
			raw := c == 'r'
			s := i
			if raw {
				s = i + 1
			}
			q := src[s]
			qq := string(q)
			triple := startsWith(src, s, strings.Repeat(qq, 3))
			ql := 1
			if triple {
				ql = 3
			}
			j := s + ql
			for j < n {
				if src[j] == '\\' && !raw {
					j += 2
					continue
				}
				if startsWith(src, j, strings.Repeat(qq, ql)) {
					j += ql
					break
				}
				if src[j] == '\n' && !triple {
					break
				}
				j++
			}
			clear(i, j)
			i = j
		default:
			i++
		}
	}
	return mask
}

func strip(r []rune) string { return strings.TrimFunc(string(r), unicode.IsSpace) }

func lstripLen(r []rune) int {
	n := 0
	for n < len(r) && unicode.IsSpace(r[n]) {
		n++
	}
	return n
}

// ReadSource reads a file like Python's text mode: UTF-8, \r\n and \r become \n.
func ReadSource(path string) ([]rune, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	s := strings.ReplaceAll(string(b), "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	return []rune(s), nil
}

// MutantsOf lists the mutants of a file in the order mutate.py finds them (line by line: operators, integers, booleans, return).
func MutantsOf(path string) ([]rune, []Mutant, error) {
	src, err := ReadSource(path)
	if err != nil {
		return nil, nil, err
	}
	return src, Mutants(src), nil
}

// Mutants is MutantsOf for a source already read.
func Mutants(src []rune) []Mutant {
	mask := CodeMask(src)
	var lines [][]rune
	start := 0
	for i := 0; i <= len(src); i++ {
		if i == len(src) || src[i] == '\n' {
			lines = append(lines, src[start:i])
			start = i + 1
		}
	}
	starts := make([]int, len(lines))
	pos := 0
	for i, ln := range lines {
		starts[i] = pos
		pos += len(ln) + 1
	}
	var out []Mutant
	for idx, ln := range lines {
		stripped := strip(ln)
		if skipLine(stripped) {
			continue
		}
		base := starts[idx]
		code := func(a, b int) bool {
			for k := a; k < b; k++ {
				if !mask[base+k] {
					return false
				}
			}
			return true
		}
		add := func(a, b int, text, op string) {
			orig := strip(ln[a:b])
			if orig == "" {
				orig = string(ln[a:b])
			}
			mut := strings.TrimFunc(text, unicode.IsSpace)
			if mut == "" {
				mut = text
			}
			out = append(out, Mutant{Line: idx + 1, Col: a + 1, Start: base + a, End: base + b, Op: op, Orig: orig, Mutant: mut, Text: text})
		}
		for _, o := range ops {
			ol := len(o.old)
			for i := 0; i+ol <= len(ln); {
				if !startsWith(ln, i, o.old) {
					i++
					continue
				}
				m0, m1 := i, i+ol
				i = m1
				if !code(m0, m1) {
					continue
				}
				if (o.old == " < " || o.old == " > ") && m0 > 0 && strings.ContainsRune("=<>", ln[m0-1]) {
					continue
				}
				add(m0, m1, o.new, o.name)
			}
		}
		// integer literals: (?<![\w.$])\d+(?![\w.])
		for i := 0; i < len(ln); {
			if !(ln[i] >= '0' && ln[i] <= '9') || (i > 0 && (isWord(ln[i-1]) || ln[i-1] == '.' || ln[i-1] == '$')) {
				i++
				continue
			}
			e := i
			for e < len(ln) && ln[e] >= '0' && ln[e] <= '9' {
				e++
			}
			from := i
			i = e
			if e < len(ln) && (isWord(ln[e]) || ln[e] == '.') {
				continue
			}
			if !code(from, e) || followedByFraction(ln[e:]) {
				continue
			}
			v, _ := new(big.Int).SetString(string(ln[from:e]), 10)
			var news []string
			switch {
			case v.Sign() == 0:
				news = []string{"1"}
			case v.Cmp(big.NewInt(1)) == 0:
				// Python builds a set here, so its order is the hash order of the run; 0 first is the natural reading
				news = []string{"0", "2"}
			default:
				news = []string{new(big.Int).Add(v, big.NewInt(1)).String()}
			}
			for _, nw := range news {
				add(from, e, nw, "int "+v.String()+" -> "+nw)
			}
		}
		// true / false: (?<![\w.$])(true|false)(?![\w$])
		for i := 0; i < len(ln); {
			if i > 0 && (isWord(ln[i-1]) || ln[i-1] == '.' || ln[i-1] == '$') {
				i++
				continue
			}
			word := ""
			switch {
			case startsWith(ln, i, "true"):
				word = "true"
			case startsWith(ln, i, "false"):
				word = "false"
			}
			if word == "" {
				i++
				continue
			}
			e := i + len(word)
			if e < len(ln) && (isWord(ln[e]) || ln[e] == '$') {
				i++
				continue
			}
			if code(i, e) {
				nw := "false"
				if word == "false" {
					nw = "true"
				}
				add(i, e, nw, word+" -> "+nw)
			}
			i = e
		}
		// return x;  ->  return <default>;  for a member typed int/bool/double/String
		ind := lstripLen(ln)
		if startsWith(ln, ind, "return ") {
			rest := ln[ind+7:]
			t := strings.TrimRightFunc(string(rest), unicode.IsSpace)
			if strings.HasSuffix(t, ";") && len([]rune(t)) >= 2 && code(ind, ind+6) {
				expr := strings.TrimSuffix(t, ";")
				for j := idx - 1; j >= 0; j-- { // nearest less indented line: the enclosing member
					if strip(lines[j]) == "" || lstripLen(lines[j]) >= ind {
						continue
					}
					if s := reMember.FindStringSubmatch(string(lines[j])); s != nil {
						def := defaults[s[1]]
						if !strings.HasSuffix(strings.TrimFunc(expr, unicode.IsSpace), def) {
							end := len([]rune(strings.TrimRightFunc(string(ln), unicode.IsSpace))) - 1
							add(ind+7, end, def, "return -> default "+def)
						}
					}
					break
				}
			}
		}
	}
	return out
}

// skipLine: import/export/part/library, assert and annotation lines have no mutants.
func skipLine(stripped string) bool {
	for _, w := range []string{"import", "export", "part", "library"} {
		if strings.HasPrefix(stripped, w) {
			rest := stripped[len(w):]
			if rest == "" {
				return true
			}
			r := []rune(rest)[0]
			if !isWord(r) {
				return true
			}
		}
	}
	return strings.HasPrefix(stripped, "assert") || strings.HasPrefix(stripped, "@")
}

// followedByFraction is re.match(r"\s*\.\d", rest).
func followedByFraction(rest []rune) bool {
	i := lstripLen(rest)
	return i+1 < len(rest) && rest[i] == '.' && rest[i+1] >= '0' && rest[i+1] <= '9'
}
