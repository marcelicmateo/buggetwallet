// Package pyrand reproduces CPython's random.Random for integer seeds: MT19937 seeded with init_by_array, getrandbits,
// _randbelow, randrange/randint, random()/uniform and shuffle. Tools that must produce the same output as the Python
// scripts they replace (fixtures, mutate) use it, so a seed gives the same numbers as `random.Random(seed)`.
package pyrand

import (
	"fmt"
	"math/big"
	"math/bits"
)

const (
	n         = 624
	m         = 397
	matrixA   = 0x9908b0df
	upperMask = 0x80000000
	lowerMask = 0x7fffffff
)

// Random is random.Random(seed).
type Random struct {
	mt  [n]uint32
	idx int
}

// New is random.Random(seed): the absolute value of the seed as little-endian 32-bit words goes to init_by_array.
func New(seed int64) *Random { return NewBig(big.NewInt(seed)) }

// NewBig is New for a seed of any size (the sign is dropped, as CPython does).
func NewBig(seed *big.Int) *Random {
	a := new(big.Int).Abs(seed)
	var key []uint32
	mask := big.NewInt(0xffffffff)
	for a.Sign() > 0 {
		key = append(key, uint32(new(big.Int).And(a, mask).Uint64()))
		a.Rsh(a, 32)
	}
	if len(key) == 0 {
		key = []uint32{0}
	}
	r := &Random{}
	r.initByArray(key)
	return r
}

func (r *Random) initGenrand(s uint32) {
	r.mt[0] = s
	for i := 1; i < n; i++ {
		r.mt[i] = 1812433253*(r.mt[i-1]^(r.mt[i-1]>>30)) + uint32(i)
	}
	r.idx = n
}

func (r *Random) initByArray(key []uint32) {
	r.initGenrand(19650218)
	i, j := 1, 0
	k := n
	if len(key) > k {
		k = len(key)
	}
	for ; k > 0; k-- {
		r.mt[i] = (r.mt[i] ^ ((r.mt[i-1] ^ (r.mt[i-1] >> 30)) * 1664525)) + key[j] + uint32(j)
		i++
		j++
		if i >= n {
			r.mt[0] = r.mt[n-1]
			i = 1
		}
		if j >= len(key) {
			j = 0
		}
	}
	for k = n - 1; k > 0; k-- {
		r.mt[i] = (r.mt[i] ^ ((r.mt[i-1] ^ (r.mt[i-1] >> 30)) * 1566083941)) - uint32(i)
		i++
		if i >= n {
			r.mt[0] = r.mt[n-1]
			i = 1
		}
	}
	r.mt[0] = 0x80000000
	r.idx = n
}

// Uint32 is genrand_uint32.
func (r *Random) Uint32() uint32 {
	if r.idx >= n {
		mag := [2]uint32{0, matrixA}
		var kk int
		for kk = 0; kk < n-m; kk++ {
			y := (r.mt[kk] & upperMask) | (r.mt[kk+1] & lowerMask)
			r.mt[kk] = r.mt[kk+m] ^ (y >> 1) ^ mag[y&1]
		}
		for ; kk < n-1; kk++ {
			y := (r.mt[kk] & upperMask) | (r.mt[kk+1] & lowerMask)
			r.mt[kk] = r.mt[kk+(m-n)] ^ (y >> 1) ^ mag[y&1]
		}
		y := (r.mt[n-1] & upperMask) | (r.mt[0] & lowerMask)
		r.mt[n-1] = r.mt[m-1] ^ (y >> 1) ^ mag[y&1]
		r.idx = 0
	}
	y := r.mt[r.idx]
	r.idx++
	y ^= y >> 11
	y ^= (y << 7) & 0x9d2c5680
	y ^= (y << 15) & 0xefc60000
	y ^= y >> 18
	return y
}

// GetRandBits is getrandbits(k) for k >= 0: k <= 32 is one word shifted down; more bits are 32-bit words with the first
// word in the low bits.
func (r *Random) GetRandBits(k int) *big.Int {
	if k < 0 {
		panic("pyrand: number of bits must be non-negative")
	}
	if k == 0 {
		return new(big.Int)
	}
	if k <= 32 {
		return new(big.Int).SetUint64(uint64(r.Uint32() >> uint(32-k)))
	}
	words := (k-1)/32 + 1
	out := new(big.Int)
	for i := 0; i < words; i++ {
		w := r.Uint32()
		if k < 32 {
			w >>= uint(32 - k)
		}
		out.Or(out, new(big.Int).Lsh(new(big.Int).SetUint64(uint64(w)), uint(32*i)))
		k -= 32
	}
	return out
}

// RandBelow is _randbelow(limit) (the getrandbits flavour): draws k = bit_length(limit) bits until the value is below limit.
func (r *Random) RandBelow(limit int) int {
	if limit <= 0 {
		return 0
	}
	k := bits.Len(uint(limit))
	for {
		v := r.GetRandBits(k).Uint64()
		if v < uint64(limit) {
			return int(v)
		}
	}
}

// RandRange is randrange(start, stop) for start < stop.
func (r *Random) RandRange(start, stop int) int {
	if stop <= start {
		panic(fmt.Sprintf("pyrand: empty range for randrange (%d, %d)", start, stop))
	}
	return start + r.RandBelow(stop-start)
}

// RandInt is randint(a, b) = randrange(a, b+1).
func (r *Random) RandInt(a, b int) int { return r.RandRange(a, b+1) }

// Float is random(): a 53-bit float from two words.
func (r *Random) Float() float64 {
	a, b := r.Uint32()>>5, r.Uint32()>>6
	return (float64(a)*67108864.0 + float64(b)) * (1.0 / 9007199254740992.0)
}

// Uniform is uniform(a, b) = a + (b-a)*random().
func (r *Random) Uniform(a, b float64) float64 { return a + (b-a)*r.Float() }

// Shuffle is shuffle(x) of CPython 3.11+: for i from len-1 down to 1, j = _randbelow(i+1), swap.
func (r *Random) Shuffle(length int, swap func(i, j int)) {
	for i := length - 1; i >= 1; i-- {
		j := r.RandBelow(i + 1)
		swap(i, j)
	}
}

// UUID4 is str(uuid.UUID(int=v, version=4)) for a 128-bit v: version and variant bits set, lower-case with dashes.
func UUID4(v *big.Int) string {
	x := new(big.Int).Set(v)
	x.AndNot(x, new(big.Int).Lsh(big.NewInt(0xc000), 48))
	x.Or(x, new(big.Int).Lsh(big.NewInt(0x8000), 48))
	x.AndNot(x, new(big.Int).Lsh(big.NewInt(0xf000), 64))
	x.Or(x, new(big.Int).Lsh(big.NewInt(4), 76))
	h := fmt.Sprintf("%032x", x)
	return h[:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}

// Hex32 is "%032x" % v.
func Hex32(v *big.Int) string { return fmt.Sprintf("%032x", v) }
