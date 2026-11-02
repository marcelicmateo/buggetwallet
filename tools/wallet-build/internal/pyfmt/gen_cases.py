# Prints the Go table of pyfmt_test.go: python3 -I gen_cases.py
import json
samples = ["abc", "it's", 'say "hi"', "both ' and \"", "tab\there", "nl\nx", "cr\r", "back\\slash", "é č ž €", "\x00\x01\x7f", "\xa0nb", "\xad", "😀", " ", "﻿", "", " "]
for s in samples:
    print("\t{%s, %s}," % (json.dumps(s, ensure_ascii=True).replace("\\u00", "\\u00"), json.dumps(repr(s), ensure_ascii=True)))
