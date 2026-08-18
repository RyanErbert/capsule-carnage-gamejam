#!/usr/bin/env python
"""Diff the parametric SPECS the client draws handles from against the ranges
the server clamps to. They live in two languages on purpose; this is what stops
them drifting into a UI whose handles quietly refuse to move.

  node -e "console.log(JSON.stringify(require('./server/parametrics.js').SPECS))" > js.json
  SPEC_OUT=gd.json godot --headless --path . --script res://_probe/models_check.gd
  python tools/spec_parity.py gd.json js.json
"""
import json, sys

gd = json.load(open(sys.argv[1]))
js = json.load(open(sys.argv[2]))
bad = 0
for t in sorted(set(gd) | set(js)):
    if t not in gd or t not in js:
        print(f"  MISSING type {t} in {'GDScript' if t not in gd else 'server'}")
        bad += 1
        continue
    for k in sorted(set(gd[t]) | set(js[t])):
        if k not in gd[t] or k not in js[t]:
            print(f"  {t}.{k} missing in {'GDScript' if k not in gd[t] else 'server'}")
            bad += 1
            continue
        a, b = gd[t][k], js[t][k]
        if any(abs(x - y) > 1e-6 for x, y in zip(a, b)):
            print(f"  {t}.{k}  gd={a}  js={b}")
            bad += 1
print("PARITY OK" if not bad else f"{bad} MISMATCHES")
sys.exit(1 if bad else 0)
