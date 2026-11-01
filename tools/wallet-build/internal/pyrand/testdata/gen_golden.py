import random, json, uuid, sys
out = {}
for seed in (0, 1, 7, 42, 2026, 2**33 + 5, -3, 123456789012345678901234567890):
    r = random.Random(seed)
    d = {}
    ks = (1, 5, 8, 31, 32, 33, 64, 100, 128, 0)
    d["bits"] = [str(r.getrandbits(k)) for k in ks]
    d["below"] = [r._randbelow(x) for x in (1, 2, 3, 7, 10, 100, 1000, 12345)]
    d["randint"] = [r.randint(5, 40) for _ in range(5)]
    d["randrange"] = [r.randrange(10, 20) for _ in range(5)]
    d["random"] = [repr(r.random()) for _ in range(3)]
    d["uniform"] = [repr(r.uniform(1, 200)) for _ in range(3)]
    xs = list(range(20)); r.shuffle(xs); d["shuffle"] = xs
    v = r.getrandbits(128)
    d["uuid"] = [str(uuid.UUID(int=v, version=4)), "%032x" % v, str(v)]
    out[str(seed)] = d
json.dump(out, open(sys.argv[1], "w"), indent=1)
