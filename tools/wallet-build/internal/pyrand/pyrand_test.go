package pyrand

import (
	"encoding/json"
	"math/big"
	"os"
	"strconv"
	"testing"
)

type golden struct {
	Bits      []string
	Below     []int
	Randint   []int
	Randrange []int
	Random    []string
	Uniform   []string
	Shuffle   []int
	UUID      []string `json:"uuid"`
}

// golden.json comes from CPython (testdata/gen_golden.py): the same calls in the same order must give the same numbers.
func TestMatchesCPython(t *testing.T) {
	raw, err := os.ReadFile("testdata/golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var all map[string]golden
	if err := json.Unmarshal(raw, &all); err != nil {
		t.Fatal(err)
	}
	if len(all) < 8 {
		t.Fatalf("golden has %d seeds", len(all))
	}
	for seedS, g := range all {
		seed, ok := new(big.Int).SetString(seedS, 10)
		if !ok {
			t.Fatal(seedS)
		}
		r := NewBig(seed)
		for i, k := range []int{1, 5, 8, 31, 32, 33, 64, 100, 128, 0} {
			if got := r.GetRandBits(k).String(); got != g.Bits[i] {
				t.Fatalf("seed %s getrandbits(%d) = %s, want %s", seedS, k, got, g.Bits[i])
			}
		}
		for i, x := range []int{1, 2, 3, 7, 10, 100, 1000, 12345} {
			if got := r.RandBelow(x); got != g.Below[i] {
				t.Fatalf("seed %s randbelow(%d) = %d, want %d", seedS, x, got, g.Below[i])
			}
		}
		for i, want := range g.Randint {
			if got := r.RandInt(5, 40); got != want {
				t.Fatalf("seed %s randint #%d = %d, want %d", seedS, i, got, want)
			}
		}
		for i, want := range g.Randrange {
			if got := r.RandRange(10, 20); got != want {
				t.Fatalf("seed %s randrange #%d = %d, want %d", seedS, i, got, want)
			}
		}
		for i, want := range g.Random {
			w, _ := strconv.ParseFloat(want, 64)
			if got := r.Float(); got != w {
				t.Fatalf("seed %s random #%d = %v, want %v", seedS, i, got, w)
			}
		}
		for i, want := range g.Uniform {
			w, _ := strconv.ParseFloat(want, 64)
			if got := r.Uniform(1, 200); got != w {
				t.Fatalf("seed %s uniform #%d = %v, want %v", seedS, i, got, w)
			}
		}
		xs := make([]int, 20)
		for i := range xs {
			xs[i] = i
		}
		r.Shuffle(len(xs), func(i, j int) { xs[i], xs[j] = xs[j], xs[i] })
		for i := range xs {
			if xs[i] != g.Shuffle[i] {
				t.Fatalf("seed %s shuffle = %v, want %v", seedS, xs, g.Shuffle)
			}
		}
		v := r.GetRandBits(128)
		if got := UUID4(v); got != g.UUID[0] {
			t.Fatalf("seed %s uuid4 = %s, want %s", seedS, got, g.UUID[0])
		}
		if got := Hex32(v); got != g.UUID[1] {
			t.Fatalf("seed %s hex = %s, want %s", seedS, got, g.UUID[1])
		}
		if v.String() != g.UUID[2] {
			t.Fatalf("seed %s int = %s, want %s", seedS, v, g.UUID[2])
		}
	}
}

func TestSeedSignIsDropped(t *testing.T) {
	a, b := New(-3), New(3)
	for i := 0; i < 5; i++ {
		if a.Uint32() != b.Uint32() {
			t.Fatal("Random(-3) must equal Random(3)")
		}
	}
}
