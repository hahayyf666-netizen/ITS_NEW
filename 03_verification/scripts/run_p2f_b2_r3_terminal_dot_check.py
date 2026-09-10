"""Check the simulation terminal-dot trace against the extracted arithmetic graph."""
from pathlib import Path
from collections import defaultdict
import json, re

ROOT=Path(__file__).resolve().parents[2]
RTL=ROOT/'02_rtl/rtl'
TB=ROOT/'03_verification/tb/p2f_dct2_64_b1_tb.sv'
TRACE=ROOT/'03_verification/sim/p2f_b2_r3_terminal_dot_trace.log'
OUT=ROOT/'03_verification/output'
caps=[64,32,16,8,4]

def table(text,name):
    return {int(k):int(v) for k,v in re.findall(r'(?m)^\s*(\d+):\s*'+re.escape(name)+r'\s*=\s*(-?\d+);',text)}

op_txt=(RTL/'p2f_b1_tables.svh').read_text(encoding='utf-8')
ev_txt=(RTL/'p2f_step102_tables.svh').read_text(encoding='utf-8')
o={n:table(op_txt,'p2f_'+n) for n in ('lane_op','op_src','op_coeff')}
t={n:table(ev_txt,'p2f102_'+n) for n in ('red_count','red_dot','red_src0','red_src1','red_terms')}

red={}
for st,cap in enumerate(caps):
    for ph in range(1,18):
        count=t['red_count'].get(st*32+ph,0)
        for sl in range(cap):
            k=st*2048+ph*64+sl
            if sl<count and t['red_dot'].get(k,-1)>=0:
                red[st,ph,sl]={
                    'dot':t['red_dot'][k], 'src0':t['red_src0'][k],
                    'src1':t['red_src1'][k], 'terms':t['red_terms'][k]}

tb=TB.read_text(encoding='utf-8')
inputs={int(c):int(h,16) for c,h in re.findall(r"case_input\[(\d+)\]\s*=\s*1024'h([0-9a-fA-F]+);",tb)}
assert inputs, 'no testbench inputs found'
def signed16(v):
    v &= 0xffff
    return v-0x10000 if v&0x8000 else v
def vector(flat): return [signed16(flat>>(16*i)) for i in range(64)]

def terminal_values(x):
    vals={}
    for ph in range(1,18):
        for st,cap in enumerate(caps):
            for sl in range(cap):
                rid=(st,ph,sl)
                if rid not in red: continue
                e=red[rid]
                parents=[]
                for src in (e['src0'],e['src1']):
                    if st==0:
                        opid=o['lane_op'][(ph-2)*128+src]
                        parents.append(x[o['op_src'][opid]]*o['op_coeff'][opid])
                    else:
                        parents.append(vals[(st-1,ph-1,src)])
                vals[rid]=parents[0]+parents[1]
    return {(e['dot'],ph): vals[(st,ph,sl)]
            for (st,ph,sl),e in red.items() if e['terms']==2**(st+1)}

expected={(vid,d,ph):v for vid,flat in inputs.items()
          for (d,ph),v in terminal_values(vector(flat)).items()}
rows=[]
for line in TRACE.read_text(encoding='utf-8').splitlines():
    if not line.strip(): continue
    ts,vid,dot,ph,val=line.split(',')
    rows.append((int(vid),int(dot),int(ph),int(val)))
seen=defaultdict(int); failures=[]
for vid,dot,ph,val in rows:
    key=(vid,dot,ph); seen[key]+=1
    if key not in expected: failures.append(f'unexpected event {key}')
    elif val!=expected[key]: failures.append(f'value mismatch {key}: got {val}, expected {expected[key]}')
for key in expected:
    if seen[key]!=1: failures.append(f'event {key} count={seen[key]}, expected 1')
result={'status':'PASS' if not failures else 'FAIL','trace_rows':len(rows),
        'expected_rows':len(expected),'vectors':len(inputs),'unique_event_keys':len(seen),
        'missing_or_duplicate_or_wrong':len(failures),'failures':failures[:50]}
(OUT/'p2f_b2_r3_terminal_dot_results.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
print(json.dumps(result,indent=2))
raise SystemExit(1 if failures else 0)
