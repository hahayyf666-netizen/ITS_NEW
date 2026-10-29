"""Check full spatial reconstruction against compiled, unmodified VTM code.

The native adapter runs TrQuant_EMT.cpp/RomTr.cpp, not a rewritten matrix
loop. LFNST preprocessing uses the separately checked frozen layout model;
the cross-check here targets the two primary inverse-transform passes.
"""
from pathlib import Path
import argparse,hashlib,json,random,re,subprocess
from validate_gate_c_model import (Descriptor,CANONICAL,load_json,apply_lfnst,
    skip_lines,inverse_2d,output_beats,LFNST_INPUT_SCAN)
from run_vtm_engineering_oracle import inverse_2d as other_inverse,profile_params
from generate_gate_c_hdl_vectors import full_engineering_cases,sparse_entries

def pack(beat): return sum((v&1023)<<(10*i) for i,v in enumerate(beat))
def image(d,entries):
    result=[[0]*d.width for _ in range(d.height)]
    for addr,value in entries: result[addr//d.width][addr%d.width]=value
    return result
def extra_cases():
    cases=[]
    for w in (4,8,16,32,64):
        for h in (4,8,16,32,64):
            for value in (512,-512):
                cases.append((f'dc_{w}x{h}_{value}',Descriptor(w,h,0,0),[(0,value)],value//32))
    rng=random.Random(20261029)
    for typ,sizes in [(0,(4,8,16,32,64)),(1,(4,8,16,32)),(2,(4,8,16,32))]:
        for n in sizes:
            entries=[(i,rng.choice((-511,-257,-127,127,257,511))) for i in range(n*n)]
            cases.append((f'dense_t{typ}_{n}',Descriptor(n,n,typ,typ),entries,None))
    for w,h in ((4,4),(4,64),(8,8),(8,16),(16,16),(64,64)):
        for s in range(4):
            for idx in (1,2):
                terms=[(r*w+c,512 if i%2==0 else -257) for i,(r,c) in enumerate(LFNST_INPUT_SCAN)]
                cases.append((f'lfnst_{w}x{h}_s{s}_i{idx}',Descriptor(w,h,0,0,s,idx),sorted(terms),None))
    for typ,n in ((0,64),(1,32),(2,32)):
        cut=32 if typ==0 else 16
        for addr in ((cut-1)*n,cut*n,cut-1,cut):
            cases.append((f'support_t{typ}_{n}_a{addr}',Descriptor(n,n,typ,typ),[(addr,512)],None))
    # Consecutive cases retain RAM payload across changes of shape and mode.
    for name,d,entries in [
        ('dirty64',Descriptor(64,64,0,0),[(i,257 if i%2 else -511) for i in range(4096)]),
        ('fresh4_zero',Descriptor(4,4,0,0),[]),
        ('fresh4x64_zero',Descriptor(4,64,0,0),[]),
        ('dirty_lfnst',Descriptor(16,16,0,0,3,2),[(r*16+c,511) for r,c in LFNST_INPUT_SCAN]),
        ('fresh_lfnst_zero',Descriptor(4,16,0,0,0,1),[]),
        ('fresh64_zero',Descriptor(64,64,0,0),[])]:
        cases.append((name,d,entries,0 if not entries else None))
    return cases

def main():
    p=argparse.ArgumentParser();p.add_argument('--native-exe',type=Path,required=True)
    p.add_argument('--evidence-dir',type=Path,required=True);args=p.parse_args()
    args.evidence_dir.mkdir(parents=True,exist_ok=True)
    canonical=load_json(CANONICAL)
    standard=[(f'gate_c_{i}',d,sparse_entries(d,0x520+i),None) for i,d in enumerate(full_engineering_cases())]
    extra=extra_cases();cases=standard+extra
    native_lines=[str(len(cases))]
    for name,d,entries,constant in cases:
        coeff=image(d,entries)
        work=apply_lfnst(coeff,d.width,d.height,d.set_idx,d.lfnst_idx,canonical,15)
        sw,sh=skip_lines(d.width,d.height,d.hor,d.ver,d.lfnst_idx)
        native_lines.append(f'{d.width} {d.height} {d.hor} {d.ver} {d.width-sw} {d.height-sh}')
        native_lines.append(' '.join(str(v) for row in work for v in row))
    payload='\n'.join(native_lines)+'\n'
    (args.evidence_dir/'native_inputs.txt').write_text(payload,encoding='ascii')
    proc=subprocess.run([str(args.native_exe.resolve())],input=payload,text=True,capture_output=True,check=True)
    (args.evidence_dir/'native_outputs.txt').write_text(proc.stdout,encoding='ascii')
    native_rows=proc.stdout.splitlines();assert len(native_rows)==len(cases)
    vectors=[str(len(extra))];manifest=[];checked=0
    primary_golden=None
    # The existing return-credit test uses this fixed legal 4x64 sparse input.
    pd=Descriptor(4,64,0,0)
    primary=other_inverse(image(pd,[(0,32767),(18,17000),(255,-32768)]),4,64,0,0,params=profile_params(10,False),canonical=canonical)
    primary_golden=output_beats(primary,'SAT10')
    for ci,((name,d,entries,constant),line) in enumerate(zip(cases,native_rows)):
        values=list(map(int,line.split()));assert len(values)==d.width*d.height
        native=[values[r*d.width:(r+1)*d.width] for r in range(d.height)]
        coeff=image(d,entries)
        a=inverse_2d(coeff,d.width,d.height,d.hor,d.ver,d.set_idx,d.lfnst_idx,canonical)
        b=other_inverse(coeff,d.width,d.height,d.hor,d.ver,lfnst_idx=d.lfnst_idx,set_idx=d.set_idx,params=profile_params(10,False),canonical=canonical)
        assert a==native, f'Gate-C/native mismatch: {name}'
        assert b==native, f'Other-model/native mismatch: {name}'
        if constant is not None: assert all(v==constant for v in values),name
        checked+=len(values)
        if ci>=len(standard):
            beats=output_beats(native,'SAT10')
            vectors.append(f'{d.pack():06x} {len(entries)} {len(beats)}')
            vectors.extend(f'{a} {v}' for a,v in entries)
            vectors.extend(f'{pack(beat):010x}' for beat in beats)
            manifest.append({'name':name,'descriptor':d.pack(),'width':d.width,'height':d.height,'hor':d.hor,'ver':d.ver,'lfnst':d.lfnst_idx,'inputs':len(entries),'beats':len(beats),'analytic_constant':constant})
    vector_bytes=('\n'.join(vectors)+'\n').encode('ascii')
    (args.evidence_dir/'full_spatial_vectors.txt').write_bytes(vector_bytes)
    # These values are separately verified against native VTM below.
    (args.evidence_dir/'primary_return_expected.hex').write_text('\n'.join(f'{pack(x):010x}' for x in primary_golden)+'\n',encoding='ascii')
    primary_payload='1\n4 64 0 0 4 32\n'+' '.join(str(v) for row in image(pd,[(0,32767),(18,17000),(255,-32768)]) for v in row)+'\n'
    raw=subprocess.check_output([str(args.native_exe.resolve())],input=primary_payload,text=True)
    vals=list(map(int,raw.split()));assert output_beats([vals[r*4:(r+1)*4] for r in range(64)],'SAT10')==primary_golden
    report={'status':'PASS_NATIVE_VTM_FULL_SPATIAL_REFERENCE','standard_cases':len(standard),'extra_cases':len(extra),'scalar_values':checked,'analytic_constant_cases':sum(c[3] is not None for c in cases),'native_executable_sha256':hashlib.sha256(args.native_exe.read_bytes()).hexdigest(),'vectors_sha256':hashlib.sha256(vector_bytes).hexdigest(),'case_manifest':manifest,'official_equivalence':'NOT_PROVEN','scope':'Native VTM primary V/H transforms; LFNST preprocessing uses frozen layout model; selected shift7/10 and SAT10 engineering profile.'}
    (args.evidence_dir/'FULL_SPATIAL_REFERENCE.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k!='case_manifest'}))
if __name__=='__main__':main()
