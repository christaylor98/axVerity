import sys, os, tempfile
sys.path.insert(0, 'wire-harness')
from waitblock import wait_new_block

d = tempfile.mkdtemp()
os.makedirs(f"{d}/.axverity-store/structure")
assert wait_new_block(d, 0, tries=3, step=0.001).startswith("TIMEOUT"), "no block: must time out"
open(f"{d}/.axverity-store/structure/block-0.bin", "w").close()
assert wait_new_block(d, 0, tries=3, step=0.001) is None, "new block: must signal"
assert wait_new_block(d, 1, tries=3, step=0.001).startswith("TIMEOUT")
print("ok")
