# Golden files for pydump_test.go: python3 -I gen_dump_golden.py testdata/golden
import json, sys, os
d = sys.argv[1]
v = {"s": "čćž \"q\" \\ \n\r\t\b\f \x01 \x7f é 😀", "i": [1, -2, 0], "f": [1.5, 0.0, 1e22, 2.5e-7, -0.0], "n": None, "b": [True, False],
     "e": {"x": [], "y": {}}, "nested": [[1, [2]], {"k": [{"a": 1}]}]}
open(os.path.join(d, "dump-indent1.json"), "w", encoding="utf-8").write(json.dumps(v, ensure_ascii=False, indent=1))
open(os.path.join(d, "dump-indent1-ascii.json"), "w", encoding="utf-8").write(json.dumps(v, indent=1))
open(os.path.join(d, "dump-compact.json"), "w", encoding="utf-8").write(json.dumps(v, ensure_ascii=False, separators=(",", ":")))
