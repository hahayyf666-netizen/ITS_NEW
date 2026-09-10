"""Read-only R1 event/connectivity audit. Writes review artifacts beside this file.

Not RTL simulation or a physical netlist proof. Parses the literal tables used
by R1, applies its loop capacities/count/dot guards, and traces live arithmetic
dependencies through every final output. No project files are modified.
"""
from pathlib import Path
from collections import Counter, defaultdict
import csv
import hashlib
import json
import re

ROOT = Path('D:/Workspace/ITS_STUDY_V35_P2F_B2_R3')
OUT = Path(__file__).resolve().parent.parent / 'output' / 'r3_static_connectivity_review'
caps = [64, 32, 16, 8, 4]
bfcaps = {4: 4, 8: 8, 16: 16, 32: 16, 64: 8}
paths = [ROOT/'02_rtl/rtl/p2f_dct2_64_b1_step102.sv',
         ROOT/'02_rtl/rtl/p2f_b1_tables.svh',
         ROOT/'02_rtl/rtl/p2f_step102_tables.svh',
         ROOT/'03_verification/output/canonical_matrices.json']
before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
rtl, optxt, evtxt = [p.read_text(encoding='utf-8') for p in paths[:3]]

def table(text, name):
    pairs = re.findall(r'(?m)^\s*(\d+):\s*'+re.escape(name)+r'\s*=\s*(-?\d+);', text)
    assert len(pairs) == len({k for k, _ in pairs}), name
    return {int(k): int(v) for k, v in pairs}

o = {n: table(optxt, 'p2f_'+n) for n in ['lane_op','op_src','op_coeff','op_dot','op_term','dot_term_count','root_sig']}
t = {n: table(evtxt, 'p2f102_'+n) for n in ['red_count','red_dot','red_node','red_terms','red_src0','red_src1','bf_count','bf_sig','bf_even_sig','bf_even_dot','bf_odd_dot','bf_high']}
assert all(re.search(rf'red_s{st}_data\s*\[0:{cap-1}\]', rtl) for st, cap in enumerate(caps))

# Enumerate only enabled RTL events, not every function entry or default.
red = {}
terms = {}
for st, cap in enumerate(caps):
    for ph in range(1,18):
        count = t['red_count'].get(st*32+ph,0)
        assert 0 <= count <= cap
        for slot in range(cap):
            k=st*2048+ph*64+slot
            if slot < count and t['red_dot'].get(k,-1)>=0:
                e = {'stage':st,'phase':ph,'slot':slot,'dot':t['red_dot'][k],
                     'node':t['red_node'][k],'terms':t['red_terms'][k],
                     'src0':t['red_src0'][k],'src1':t['red_src1'][k]}
                red[st,ph,slot] = e
                if e['terms']==2**(st+1):
                    assert e['dot'] not in terms
                    terms[e['dot']]=e
assert set(terms)==set(range(64))
assert len(red)==len(t['red_dot'])==1304

# Symbolic coefficient vectors: every product/reduction/butterfly value remains
# a linear combination of the 64 original inputs. This proves all 4096 raw
# matrix coefficients, rather than sampling a few numerical vectors.
vals, deps, memberships = {}, {}, {}
def add(a,b):return tuple(x+y for x,y in zip(a,b))
for ph in range(1,18):
    for st,cap in enumerate(caps):
        for sl in range(cap):
            rid=(st,ph,sl)
            if rid not in red:continue
            e=red[rid]
            parents=[]
            for src in [e['src0'],e['src1']]:
                if st==0:
                    opid=o['lane_op'][(ph-2)*128+src]
                    assert o['op_dot'][opid]==e['dot']
                    parent=('op',opid)
                    z=[0]*64; z[o['op_src'][opid]]=o['op_coeff'][opid]
                    vals[parent]=tuple(z); deps[parent]=[]
                    memberships[parent]={opid}
                else:
                    pid=(st-1,ph-1,src)
                    assert pid in red, ('missing previous-cycle producer',rid,pid)
                    assert red[pid]['dot']==e['dot']
                    parent=('red',)+pid
                parents.append(parent)
            node=('red',)+rid
            assert not (memberships[parents[0]] & memberships[parents[1]])
            vals[node]=add(vals[parents[0]],vals[parents[1]])
            deps[node]=parents
            memberships[node]=memberships[parents[0]] | memberships[parents[1]]
for dot,e in terms.items():
    node=('dot',dot); par=('red',e['stage'],e['phase'],e['slot'])
    vals[node]=vals[par]; deps[node]=[par]
    assert len(memberships[par])==o['dot_term_count'][dot]

bf=[]
signal_producers={}
for ph in range(1,18):
    for level,cap in bfcaps.items():
        for slot in range(cap):
            k=level*2048+ph*64+slot
            if slot>=t['bf_count'].get(level*32+ph,0) or t['bf_sig'].get(k,-1)<0:continue
            sid=t['bf_sig'][k]; es=t['bf_even_sig'][k]
            even=('sig',es) if es>=0 else ('dot',t['bf_even_dot'][k])
            odd=('dot',t['bf_odd_dot'][k])
            for par in [even,odd]:
                assert par in vals
                pp=signal_producers[par[1]]['phase'] if par[0]=='sig' else terms[par[1]]['phase']
                assert pp<ph, ('same-edge or future butterfly dependency',par,ph)
            node=('sig',sid)
            assert sid not in signal_producers
            vals[node]=tuple(a-b if t['bf_high'][k] else a+b for a,b in zip(vals[even],vals[odd]))
            deps[node]=[even,odd]
            event={'level':level,'phase':ph,'slot':slot,'sig':sid,'even':even,'odd':odd,'high':t['bf_high'][k]}
            bf.append(event);signal_producers[sid]=event
assert len(bf)==124
live=set()
def visit(node):
    if node in live:return
    live.add(node)
    for parent in deps[node]:visit(parent)
for i in range(64):visit(('sig',o['root_sig'][i]))
live_red={n[1:] for n in live if n[0]=='red'}
live_ops={n[1] for n in live if n[0]=='op'}
assert live_red==set(red)
assert live_ops==set(range(1368))
canonical=json.loads(paths[3].read_text(encoding='utf-8'))
A=canonical['transforms']['0']['inverse_operator']['64']
assert all(list(vals['sig',o['root_sig'][i]])==A[i] for i in range(64))

src_sets=defaultdict(lambda:defaultdict(list))
for rid in live_red:
    e=red[rid]
    src_sets[e['stage'],e['slot']][e['src0'],e['src1']].append(e['phase'])
slot_rows=[]
for (st,sl),pairs in sorted(src_sets.items()):
    slot_rows.append({'stage':st,'slot':sl,'pair_count':len(pairs),
                     'choices':[{'source_pair':list(pair),'phases':sorted(ph)} for pair,ph in sorted(pairs.items())]})
assert Counter(r['pair_count'] for r in slot_rows)=={1:96,2:28}

# Liveness/context hazard check on a four-vector II=16 logical event overlay.
# A phase here is a schedule label; it is not a top-port absolute cycle.
dot_mem={};sig_mem={};completions=defaultdict(list)
events=defaultdict(list)
for vec in range(4):
    for d,e in terms.items():events[16*vec+e['phase']].append(('write',vec,d))
    for e in bf:events[16*vec+e['phase']].append(('read',vec,e))
for tick,es in sorted(events.items()):
    writes=[];signals=[]
    for kind,vec,e in es:
        if kind=='write':
            writes.append((vec%2,e,vec));completions[tick].append([vec,e,terms[e]['stage']])
        else:
            for p in [e['even'],e['odd']]:
                actual=sig_mem.get(p[1]) if p[0]=='sig' else dot_mem.get((vec%2,p[1]))
                assert actual==vec, ('context/dependency mismatch',tick,vec,p,actual)
            signals.append((e['sig'],vec))
    assert len({(bank,d) for bank,d,vec in writes})==len(writes)
    for bank,d,vec in writes:dot_mem[bank,d]=vec
    for sig,vec in signals:sig_mem[sig]=vec
peak=max(map(len,completions.values()))
assert peak==8

butterfly_slots=[]
for level,cap in bfcaps.items():
    for slot in range(cap):
        es=[e for e in bf if e['level']==level and e['slot']==slot]
        butterfly_slots.append({'level':level,'slot':slot,'event_count':len(es),
            'even_sources':sorted({e['even'] for e in es}),
            'odd_sources':sorted({e['odd'] for e in es}),
            'destinations':sorted({e['sig'] for e in es}),
            'phases':sorted({e['phase'] for e in es})})
result={'status':'PASS_STATIC_TABLE_ANALYSIS','scope':'Reachable/live RTL schedule slots; not synthesized-cell or physical-layout proof',
        'r1_files_sha256':before,'reachable_live_reduction_events':len(live_red),'live_operations':len(live_ops),
        'raw_matrix_coefficient_matches':4096,'slot_pair_histogram':dict(Counter(r['pair_count'] for r in slot_rows)),
        'reduction_slots':slot_rows,'dot_producers':[dict(dot=d,**{k:v for k,v in terms[d].items() if k!='dot'}) for d in range(64)],
        'completion_peak_four_vectors_ii16':peak,
        'single_vector_completions':{ph:[d for d in range(64) if terms[d]['phase']==ph] for ph in range(1,18) if any(e['phase']==ph for e in terms.values())},
        'butterfly_slots':butterfly_slots,
        'limitations':['No R3 RTL exists or was generated','No post-synthesis netlist proof','Physical locality not proved by adjacent register indices','Four-vector overlay uses frozen schedule phases, not an RTL state-machine simulation']}
assert before=={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
OUT.mkdir(exist_ok=True)
(OUT/'r1_static_connectivity_review.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
with (OUT/'r1_dot_producer_map.csv').open('w',newline='',encoding='utf-8-sig') as f:
    writer=csv.DictWriter(f,fieldnames=['dot','stage','slot','phase','terms','src0','src1','node'])
    writer.writeheader();writer.writerows(result['dot_producers'])
manifest = {
    'schema':'p2f_b2_r3_connectivity_manifest_v1',
    'source':'mechanically extracted from R3-copied R1 RTL/tables',
    'status': result['status'],
    'reduction_slots': result['reduction_slots'],
    'dot_producers': result['dot_producers'],
    'single_vector_completions': result['single_vector_completions'],
    'completion_peak_four_vectors_ii16': result['completion_peak_four_vectors_ii16'],
    'sampling_semantics':'current-cycle arithmetic expression; no terminal-register old-value substitution'
}
(OUT.parent/'p2f_b2_r3_connectivity_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
(OUT.parent/'p2f_b2_r3_static_connectivity.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
(OUT.parent/'V35_P2F_B2_R3_STATIC_CONNECTIVITY_PROOF.md').write_text(
    '# V35 P2F B2 R3 Static Connectivity Proof\n\n'
    f"Status: **{result['status']}**\\n\\n"
    f"Live reduction events: {len(live_red)}\\n\\n"
    f"Live operations: {len(live_ops)}\\n\\n"
    'Canonical raw matrix: 4096/4096 elements match.\\n\\n'
    'Source-pair histogram: 96 fixed, 28 two-choice, 0 invalid (>2).\\n\\n'
    'All 64 dots have exactly one terminal producer; completion peak is 8.\\n\\n'
    'This proves reachable schedule connectivity, not synthesized-cell topology or post-route timing.\n', encoding='utf-8')
print(json.dumps({'status':result['status'],'live_reduction_events':len(live_red),'live_operations':len(live_ops),
                  'raw_matrix_matches':4096,'fixed_slots':96,'two_choice_slots':28,'peak_completions':peak,
                  'full_dot_map':str(OUT/'r1_dot_producer_map.csv'),'details':str(OUT/'r1_static_connectivity_review.json')},indent=2))
