from pathlib import Path
import sys, json, random
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'03_verification/step12d_engineering'))
from validate_gate_c_model import Descriptor, load_json, CANONICAL, inverse_2d, apply_lfnst, skip_lines, transform_matrix, round_clip, output_beats

import argparse
p=argparse.ArgumentParser();p.add_argument('--output-dir',type=Path,required=True)
out=p.parse_args().output_dir;out.mkdir(parents=True,exist_ok=True)
canonical=load_json(CANONICAL)
def full_spatial_inverse(coeff,d):
    # Keep the frozen input-frequency support and fixed-point rules, but
    # reconstruct ALL spatial rows. VTM xIT passes skipHeight as iSkipLine2
    # (input frequency truncation), not as an output sample truncation.
    work=apply_lfnst(coeff,d.width,d.height,d.set_idx,d.lfnst_idx,canonical,15)
    sw,sh=skip_lines(d.width,d.height,d.hor,d.ver,d.lfnst_idx)
    cw,ch=d.width-sw,d.height-sh
    vm=transform_matrix(canonical,d.ver,d.height)
    hm=transform_matrix(canonical,d.hor,d.width)
    tmp=[[0]*d.width for _ in range(d.height)]
    for col in range(cw):
        for row in range(d.height):
            tmp[row][col]=round_clip(sum(vm[row][k]*work[k][col] for k in range(ch)),7,-32768,32767)
    return [[round_clip(sum(hm[col][k]*tmp[row][k] for k in range(cw)),10,-32768,32767) for col in range(d.width)] for row in range(d.height)]
def pack(values): return sum((v&1023)<<(10*i) for i,v in enumerate(values))
specs=[]
for typ,sizes in [(0,[4,8,16,32,64]),(1,[4,8,16,32]),(2,[4,8,16,32])]:
    for n in sizes:
        for pattern in ('dc','dense'):
            specs.append((f't{typ}_{n}x{n}_{pattern}',Descriptor(n,n,typ,typ),pattern))
for w,h in [(4,64),(64,4),(16,32),(32,16)]:
    specs.append((f'dct2_{w}x{h}_dc',Descriptor(w,h,0,0),'dc'))
for w,h in [(4,4),(4,16),(8,8),(8,16),(16,16),(64,64)]:
    specs.append((f'lfnst_{w}x{h}',Descriptor(w,h,0,0,0,1),'lfnst'))
lines=[str(len(specs))]; manifests=[]
for index,(name,d,pattern) in enumerate(specs):
    coeff=[[0]*d.width for _ in range(d.height)]
    if pattern=='dc': coeff[0][0]=512
    elif pattern=='dense':
        rng=random.Random(20261029+index)
        for row in range(d.height):
            for col in range(d.width):
                coeff[row][col]=rng.choice([-511,-257,-127,127,257,511])
    else:
        for row in range(4):
            for col in range(4): coeff[row][col]=512 if (row+col)%2==0 else -257
    entries=[(r*d.width+c,v) for r,row in enumerate(coeff) for c,v in enumerate(row) if v]
    current=inverse_2d(coeff,d.width,d.height,d.hor,d.ver,d.set_idx,d.lfnst_idx,canonical)
    reference=full_spatial_inverse(coeff,d)
    if pattern=='dc' and d.hor==0 and d.ver==0:
        # Independent analytic check: DC basis is 64 everywhere;
        # ((512*64+64)>>7)=256; ((256*64+512)>>10)=16.
        assert all(v==16 for row in reference for v in row)
    a=output_beats(current,'SAT10'); b=output_beats(reference,'SAT10')
    lines.append(f'{d.pack():06x} {len(entries)} {len(a)}')
    lines.extend(f'{addr} {v}' for addr,v in entries)
    lines.extend(f'{pack(x):010x} {pack(y):010x}' for x,y in zip(a,b))
    manifests.append({'index':index,'name':name,'width':d.width,'height':d.height,'hor':d.hor,'ver':d.ver,'lfnst':d.lfnst_idx,'pattern':pattern,'input_points':len(entries),'expected_differing_samples':sum(x!=y for ar,br in zip(current,reference) for x,y in zip(ar,br))})
(out/'probe_vectors.txt').write_text('\n'.join(lines)+'\n',encoding='ascii')
(out/'cases.json').write_text(json.dumps(manifests,indent=2),encoding='utf-8')
print(json.dumps({'cases':len(specs),'model_disagreements':sum(x['expected_differing_samples']>0 for x in manifests)}))
