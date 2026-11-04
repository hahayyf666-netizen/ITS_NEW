import sys
sys.path.insert(0, r"C:\Users\Fine\Documents\deepseek-harness\default-workspace\its_push\03_verification\step12d_engineering")
from validate_gate_c_model import Descriptor, CANONICAL, load_json, inverse_2d, output_beats

canonical = load_json(CANONICAL)

def tu(set_idx, lfnst_idx, dc):
    w = h = 4
    coeff = [[0]*w for _ in range(h)]
    coeff[0][0] = dc
    d = Descriptor(w, h, 0, 0, set_idx, lfnst_idx)
    wide = inverse_2d(coeff, w, h, 0, 0, set_idx, lfnst_idx, canonical)
    low = [v for b in output_beats(wide, "LOW10") for v in b]
    sat = [v for b in output_beats(wide, "SAT10") for v in b]
    info = w | (h << 7) | (0 << 14) | (0 << 16) | (set_idx << 18) | (lfnst_idx << 20)
    return info, sat, wide

for name, s, l, dc in [("L1",0,1,512), ("L2",1,2,-512), ("P_HI",0,0,32767), ("P_LO",0,0,-32768)]:
    info, sat, wide = tu(s, l, dc)
    beats = [sat[i:i+4] for i in range(0,16,4)]
    print(f"{name}: info=22'h{info:06x} set={s} lfnst={l} dc={dc}")
    print(f"   wide[0][:4]={wide[0][:4]}")
    print(f"   sat beats={beats}")
