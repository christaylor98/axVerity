import sys; sys.path.insert(0,'wire-harness')
from wp import *
P=47311
# ADMIT (op 3) argument discovery
one(P, bytes([3])+leb(0), "admit count=0")
one(P, bytes([3])+leb(1), "admit count=1, no records")
one(P, bytes([3])+leb(1)+s_("a")+s_("b")+s_("c"), "admit count=1 + 3 strings", timeout=3.0)
