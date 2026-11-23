#!/usr/bin/env python3
"""Port the SUSFS SUS_MAP hunks of fs/proc/task_mmu.c to the OnePlus 6.12.58 tree.

Upstream SUSFS targets a newer android16-6.12 where show_smap() uses vma_data_pages()
and show_smaps_rollup() has a different loop. In the OnePlus tree those 3 hunks are
rejected, so apply the same logic here:
  * show_smap(): print nothing for a sus-map VMA
  * show_smaps_rollup(): do not add a sus-map VMA to the rollup totals
"""
import re
import sys

path = sys.argv[1]
src = open(path, encoding="utf-8").read()

if "SUSFS_VMA_IS_SUS_MAP" in src:
    print("task_mmu.c already fixed")
    sys.exit(0)

def die(msg):
    print(f"::error::fix_task_mmu: {msg}")
    sys.exit(1)

# 1) show_smap(): skip sus-map VMAs before anything is printed
m = re.search(r"static int show_smap\(struct seq_file \*m, void \*v\)\n\{\n"
              r"\tstruct vm_area_struct \*vma = v;\n"
              r"\tstruct mem_size_stats mss = \{\};\n\n", src)
if not m:
    die("show_smap() prologue not found")
guard = ("#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
         "\tif (vma->vm_file) {\n"
         "\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n"
         "\t\t\treturn 0;\n"
         "\t}\n"
         "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\n")
src = src[:m.end()] + guard + src[m.end():]

# 2) show_smaps_rollup(): guard every smap_gather_stats() call inside the function
start = src.find("static int show_smaps_rollup(struct seq_file *m, void *v)")
if start < 0:
    die("show_smaps_rollup() not found")
end = src.find("\n}\n", start)
if end < 0:
    die("end of show_smaps_rollup() not found")
body = src[start:end]
body, n = re.subn(r"(?m)^(\t+)(smap_gather_stats\(vma, &mss, [^;]+\);)$",
                  r"\1if (!SUSFS_VMA_IS_SUS_MAP(vma))\n\1\t\2", body)
if n < 2:
    die(f"expected at least 2 smap_gather_stats() calls in show_smaps_rollup(), found {n}")
helper = ("#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n"
          "#define SUSFS_VMA_IS_SUS_MAP(vma) \\\n"
          "\t((vma)->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode((vma)->vm_file)))\n"
          "#else\n"
          "#define SUSFS_VMA_IS_SUS_MAP(vma) 0\n"
          "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\n")
src = src[:start] + helper + body + src[end:]

if "linux/susfs_def.h" not in src:
    die("susfs_def.h include missing (hunk 1 of the SUSFS patch did not apply)")

open(path, "w", encoding="utf-8").write(src)
print(f"task_mmu.c: show_smap guarded, {n} smap_gather_stats() calls guarded in show_smaps_rollup")
