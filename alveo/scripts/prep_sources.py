#!/usr/bin/env python3
"""Produce fully self-contained RTL for the Vitis (Vivado) flow.

The original core was written for ISE 14.7 on one machine and hardcodes absolute
include paths like `\\`include "/home/hermes/microgpt_fpga/core/core_params.vh"`.
Absolute includes ignore include dirs, and packaged-IP include-path handling is fragile,
so we **inline** every `\\`include` textually into the `.v` files. Output: one
self-contained Verilog file per module in alveo/gen_src/ -- no includes, no include dirs,
nothing for the packager to lose. Every `\\`include` in the core is module-scoped, so
inlining is semantically identical.

Nothing under core/ is mutated, so the original Virtex-5/ISE flow still builds.
"""
import os, re, shutil, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
CORE = os.path.join(REPO, "core")
GEN  = os.path.join(REPO, "alveo", "gen_src")

INCLUDE = re.compile(r'^[ \t]*`include[ \t]+"(?:.*/)?([^"/]+)"[ \t]*$')

# Reused RTL: the whole inference core + the autoregressive driver.
CORE_V = ["attn", "embed", "exp_unit", "grom", "isqrt", "matvec", "microgpt_core",
          "norm", "sampler", "udiv", "vecop", "vmem", "vmem2", "wrom"]
EXTRA  = [("name_generator", os.path.join(REPO, "board", "name_generator.v"))]


def find_inc(name):
    for d in (CORE, REPO, os.path.join(REPO, "board")):
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    return None


def inline(path, stack):
    if path in stack:
        sys.exit(f"ERROR: include cycle at {path}")
    out = []
    with open(path) as f:
        for line in f:
            m = INCLUDE.match(line)
            if m:
                inc = find_inc(m.group(1))
                if inc is None:
                    sys.exit(f"ERROR: cannot resolve `include \"{m.group(1)}\" from {path}")
                out.append(f"// ---- inlined: {m.group(1)} ----\n")
                out.append(inline(inc, stack + [path]))
                out.append(f"// ---- end inlined: {m.group(1)} ----\n")
            else:
                out.append(line)
    return "".join(out)


def main():
    if os.path.exists(GEN):
        shutil.rmtree(GEN)
    os.makedirs(GEN)

    files = [(n, os.path.join(CORE, n + ".v")) for n in CORE_V] + EXTRA
    missing = [p for _, p in files if not os.path.exists(p)]
    if missing:
        sys.exit("ERROR: missing sources:\n  " + "\n  ".join(missing))

    for name, src in files:
        flat = inline(src, [])
        if re.search(r'`include', flat):
            sys.exit(f"ERROR: unresolved `include left in flattened {name}")
        with open(os.path.join(GEN, name + ".v"), "w") as f:
            f.write(flat)

    print(f"prep_sources: wrote {len(files)} self-contained files to {GEN}")


if __name__ == "__main__":
    main()
