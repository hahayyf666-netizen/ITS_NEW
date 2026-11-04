"""Evidence dependencies and successful-run receipts. Local consistency, not tamper proof."""
import argparse, hashlib, json, subprocess, sys
from pathlib import Path
AUDIT=Path(__file__).resolve().parents[1]
REPO=AUDIT.parent/'its_push'
FIXTURE=AUDIT.parent/'work_endattr'
BASE=AUDIT/'gate/baseline_v2.json'
def digest(p): return hashlib.sha256(p.read_bytes().replace(b'\r\n',b'\n')).hexdigest()
def save(p,x): p.write_text(json.dumps(x,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
def dependencies(kind):
    paths=[]
    roots=([REPO/'02_rtl/rtl',REPO/'03_verification/vivado'] if kind=='physical' else
           [REPO/'02_rtl/rtl',REPO/'03_verification/tb',REPO/'03_verification/step12d_engineering',
            REPO/'03_verification/regression_baseline',REPO/'04_reference/VTM/source/Lib/CommonLib'])
    exts={'.sv','.v','.vh','.svh','.hex','.py','.ps1','.tcl','.xdc','.json','.cpp','.h','.inc'}
    for root in roots:
        paths.extend(p for p in root.rglob('*') if p.is_file() and p.suffix in exts)
    if kind=='functional':
        paths += [REPO/'03_verification/output/canonical_matrices.json']
        paths += list((REPO/'05_audit/current/27/step12d_engineering').glob('*.json'))
        paths += [FIXTURE/n for n in ['end_attribution_lfnst_overlap_tb.sv','final_saturate_dual_tb.sv','reset_first_read_tb.sv','p2_stim.hex','p2_sat.hex','p2_low.hex']]
        paths += list((AUDIT/'run').glob('*.py'))+list((AUDIT/'run').glob('*.ps1'))+list((AUDIT/'gate').glob('*.py'))
    result={str(p.resolve()):digest(p) for p in sorted(set(paths))}
    if kind=='physical':
        manifest=json.loads((REPO/'05_audit/current/104_end_attribution_timing_20261104/physical/SOURCE_ARTIFACT_HASHES.json').read_text(encoding='utf-8-sig'))
        for n in manifest['inputs_sha256']:
            if not (REPO/n).exists():
                q=subprocess.run(['git','show','HEAD:'+n],cwd=REPO,capture_output=True)
                if q.returncode: raise RuntimeError('Missing physical dependency '+n)
                result['git:HEAD:'+n]=hashlib.sha256(q.stdout.replace(b'\r\n',b'\n')).hexdigest()
    return result
def versions():
    commands={'simulation':['D:/software/Modelsim/win64/vsim.exe','-version'],
              'synthesis':['D:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat','-version']}
    result={}
    for k,c in commands.items():
        q=subprocess.run(c,capture_output=True,text=True,timeout=60)
        text=(q.stdout+q.stderr).strip()
        # This installed Vivado -version returns 1 even with a complete version banner.
        valid=('vivado v2025.2' in text.lower() and 'SW Build 6299465' in text) if k=='synthesis' else ('ModelSim' in text and q.returncode==0)
        if not valid: raise RuntimeError('Tool version query failed: '+k)
        result[k]={'banner':text,'query_exit_code':q.returncode}
    return result
def receipt_errors(receipt):
    errors=[]
    if receipt.get('verdict')!='PASS': errors.append('receipt is not a complete PASS')
    if receipt.get('inputs_before')!=receipt.get('inputs_after'): errors.append('inputs changed during run')
    if receipt.get('inputs_after')!=dependencies('functional'): errors.append('functional receipt dependencies stale')
    for name,h in receipt.get('artifacts',{}).items():
        if not Path(name).is_file() or digest(Path(name))!=h: errors.append('artifact missing/changed: '+name)
    if not receipt.get('artifacts'): errors.append('receipt has no artifacts')
    return errors
def physical_check():
    root=REPO/'05_audit/current/104_end_attribution_timing_20261104'
    m=json.loads((root/'physical/SOURCE_ARTIFACT_HASHES.json').read_text(encoding='utf-8-sig'))
    errors=[]
    # Historical raw SHA may reflect CRLF or LF; accept only those two representations.
    for group,base in [('inputs_sha256',REPO),('reports_sha256',root)]:
        for n,h in m[group].items():
            p=base/n
            if not p.is_file():
                if group!='inputs_sha256': errors.append('missing '+n);continue
                q=subprocess.run(['git','show','HEAD:'+n],cwd=REPO,capture_output=True)
                if q.returncode: errors.append('missing '+n);continue
                raw=q.stdout
            else: raw=p.read_bytes()
            lf=raw.replace(b'\r\n',b'\n')
            candidates=[raw,lf,lf.replace(b'\n',b'\r\n')]
            if h not in [hashlib.sha256(b).hexdigest() for b in candidates]: errors.append('mismatch '+n)
    return {'source_and_reports_match':not errors,'errors':errors,
            'sparse_dependency_policy':'Missing checked-out physical inputs are verified from HEAD Git objects; not a runnable physical checkout.',
            'scope':'Historical registered-neighbor nominal timing only; no new physical run or netlist functional proof.'}
def check(base):
    tools=versions(); out={'schema':'its.evidence_gate.v2','official_equivalence':'NOT_PROVEN'}
    for k in ['functional','physical']:
        now=dependencies(k);old=base.get(k,{})
        out[k]={'changed':sorted(n for n in set(now)|set(old) if now.get(n)!=old.get(n))}
    receipt=Path(base['receipt']);errors=[]
    if not receipt.is_file() or digest(receipt)!=base['receipt_sha256']: errors.append('receipt missing/changed')
    else: errors+=receipt_errors(json.loads(receipt.read_text(encoding='utf-8-sig')))
    out['receipt_errors']=errors
    out['tools_match']=tools==base.get('tools')
    out['functional_evidence_valid']=not out['functional']['changed'] and not errors and out['tools_match']
    out['historical_physical']=physical_check()
    out['physical_evidence_valid']=not out['physical']['changed'] and out['tools_match'] and out['historical_physical']['source_and_reports_match']
    out['status']='PASS' if out['functional_evidence_valid'] and out['physical_evidence_valid'] else 'STALE'
    return out

def main():
    a=argparse.ArgumentParser();a.add_argument('--snapshot',action='store_true');a.add_argument('--check',action='store_true');a.add_argument('--selftest',action='store_true');a.add_argument('--evidence',type=Path);x=a.parse_args()
    if x.selftest:
        import importlib.util
        spec=importlib.util.spec_from_file_location('closure_runner',AUDIT/'run/closure_runner.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
        return m.selftest()
    if x.snapshot:
        if not x.evidence: raise RuntimeError('--snapshot requires --evidence from successful complete run')
        receipt=json.loads(x.evidence.read_text(encoding='utf-8-sig'));errors=receipt_errors(receipt)
        if errors: raise RuntimeError(str(errors))
        save(BASE,{'functional':dependencies('functional'),'physical':dependencies('physical'),'tools':receipt['tools'],'receipt':str(x.evidence.resolve()),'receipt_sha256':digest(x.evidence),'trust':'Local receipt, not a signature or protection against deliberate rewriting.'})
        return 0
    if x.check:
        if not BASE.exists(): print('No qualified v2 baseline');return 2
        out=check(json.loads(BASE.read_text(encoding='utf-8')));save(AUDIT/'gate/gate_result_v2.json',out);print(out['status']);return 0 if out['status']=='PASS' else 2
    return 2
if __name__=='__main__':sys.exit(main())
