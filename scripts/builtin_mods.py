#!/usr/bin/env python3
"""Build two userspace KernelSU modules into the kernel source tree.

usage: builtin_mods.py <kernel source root (common/)> <repo dir> [block,list]

1. fgetpriority: copy patches/fgetpriority.h to include/linux/ and make
   getpriority/setpriority (kernel/sys.c) and ioprio_get/ioprio_set
   (block/ioprio.c) call fgp_find_user() instead of find_user().
2. sg_unblock: vendor modules named in the comma-separated block list
   (default: oplus_secure_guard_new) are refused by load_module(), the same
   path as the module_blacklist= boot parameter, so they never load.

Only function bodies change: no exported symbol or struct, so the KMI CRCs
stay identical to stock. Idempotent: running it twice is fine.
"""
import os
import re
import shutil
import sys

src, repo = sys.argv[1], sys.argv[2]
block = sys.argv[3] if len(sys.argv) > 3 else "oplus_secure_guard_new"
MARK = "OP15_BUILTIN_MODS"


def die(msg):
    print(f"::error::builtin_mods: {msg}")
    sys.exit(1)


def edit(rel, fn):
    path = os.path.join(src, rel)
    text = open(path, encoding="utf-8").read()
    if MARK in text:
        print(f"{rel}: already done")
        return
    new = fn(text)
    open(path, "w", encoding="utf-8").write(new)
    print(f"{rel}: patched")


# ---------------------------------------------------------------- fgetpriority
shutil.copyfile(os.path.join(repo, "patches", "fgetpriority.h"),
                os.path.join(src, "include", "linux", "fgetpriority.h"))


def use_fgp(text, rel):
    # Upstream has 2 per file (the PRIO_USER branch of each syscall); vendor trees
    # may carry more copies of the same branch. Every one is a PRIO_USER lookup.
    call = re.compile(r"\bfind_user\(\s*uid\s*\)")
    lines = [i + 1 for i, l in enumerate(text.splitlines()) if call.search(l)]
    if len(lines) < 2:
        die(f"{rel}: expected at least 2 find_user(uid) calls, found {len(lines)}")
    print(f"{rel}: find_user(uid) -> fgp_find_user(uid) at lines {lines}")
    text = call.sub("fgp_find_user(uid)", text)
    anchor = "#include <linux/cred.h>\n"
    if anchor not in text:
        die(f"{rel}: no '#include <linux/cred.h>' to anchor the include")
    return text.replace(anchor, anchor + f"#include <linux/fgetpriority.h> /* {MARK} */\n", 1)


edit("kernel/sys.c", lambda t: use_fgp(t, "kernel/sys.c"))
edit("block/ioprio.c", lambda t: use_fgp(t, "block/ioprio.c"))

# ---------------------------------------------------------------- vendor module block list
if not re.fullmatch(r"[A-Za-z0-9_,]*", block):
    die(f"bad block list {block!r}")


def block_mods(text):
    sig = "static bool blacklisted(const char *module_name)\n{\n\tconst char *p;\n\tsize_t len;\n"
    if sig not in text:
        die("kernel/module/main.c: blacklisted() not in the expected form")
    check = (
        f"\n\t/* {MARK}: vendor modules that must never load */\n"
        f"\tfor (p = \"{block}\"; *p; p += len) {{\n"
        "\t\tlen = strcspn(p, \",\");\n"
        "\t\tif (len && strlen(module_name) == len && !memcmp(module_name, p, len))\n"
        "\t\t\treturn true;\n"
        "\t\tif (p[len] == ',')\n"
        "\t\t\tlen++;\n"
        "\t}\n"
    )
    return text.replace(sig, sig + check, 1)


if block:
    edit("kernel/module/main.c", block_mods)
print(f"fgetpriority: built in; blocked vendor modules: {block or '(none)'}")
