"""Fail-closed, bounded closure runner; evidence remains scoped to engineering rules."""
import argparse, importlib.util, json, os, re, shutil, subprocess, sys, time
from pathlib import Path
AUDIT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('gate',AUDIT/'gate/evidence_gate.py');gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)
RTL=['its_simple_ram.sv','its_input_cache_bank.sv','unified_p4_kernel.sv','bounded_lfnst_engine.sv','unified_its_wrapper.sv','its_unified_submission_top.sv']
SUITES={'P1':('end_attribution_lfnst_overlap_tb',4,'LFNST_OVERLAP_TB'), 'P2':('final_saturate_dual_tb',0,'P2_PASS'),'P4':('reset_first_read_tb',5,'RESET_FIRST_READ_TB')}
def verdict(stages):
    required=['dependency_preflight','P1_normal','P1_synthesis','P2_normal','P2_synthesis','P4_normal','P4_synthesis','full_regression','inputs_stable']
    return 'PASS' if all(stages.get(n,{}).get('status')=='PASS' for n in required) else 'INCOMPLETE' if any(v.get('status')=='SKIP' for v in stages.values()) else 'FAIL'
def assess(name,text,rc):
    module,count,marker=SUITES[name]
    if rc or re.search(r'\*\* (?:Fatal|Error):|RESULT=FAIL',text):return False
    if 'Errors: 0, Warnings: 0' not in text or marker not in text:return False
    if count:
        cases=re.findall(r'^# CASE (\S+) RESULT=(PASS|FAIL)\s*$',text,re.M)
        if len(cases)!=count or len(dict(cases))!=count or any(v!='PASS' for _,v in cases):return False
        if f'{marker} pass={count} fail=0' not in text:return False
    if name=='P1':
        coverage={}
        for case,fields in re.findall(r'^# COVER_P1 case=(S\d+) (.+)$',text,re.M):
            coverage[case]={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',fields)}
        if set(coverage)!={'S05','S06','S07','S08'}:return False
        if any(v.get('lfnst_active',0)<=0 or v.get('kernel_and_lfnst',0)!=0 for v in coverage.values()):return False
        if coverage['S05'].get('queue_two',0)<=0 or coverage['S06'].get('desc_while_lfnst',0)<=0:return False
        if coverage['S08'].get('desc_while_lfnst',0)<=0 or coverage['S08'].get('stall',0)<=100:return False
    if name=='P2':
        m=re.search(r'P2_RESULT beats=(\d+) sat_mismatch=0 low_mismatch=0 diff_beats=(\d+) vld_skew=0 done_sat=8 done_low=8',text)
        if not m or not all(int(x)>0 for x in m.groups()):return False
    return True

def selftest():
    import tempfile
    checks={}
    good='# Errors: 0, Warnings: 0\n# P2_RESULT beats=32 sat_mismatch=0 low_mismatch=0 diff_beats=8 vld_skew=0 done_sat=8 done_low=8\n# P2_PASS\n'
    checks['valid_result']=assess('P2',good,0)
    checks['nonzero_exit']=not assess('P2',good,1)
    checks['missing_marker']=not assess('P2',good.replace('P2_PASS',''),0)
    checks['fatal_with_zero_exit']=not assess('P2',good+'** Fatal: test\n',0)
    checks['mismatch_with_zero_exit']=not assess('P2',good.replace('sat_mismatch=0','sat_mismatch=1'),0)
    checks['empty_log']=not assess('P2','',0)
    names=['dependency_preflight','P1_normal','P1_synthesis','P2_normal','P2_synthesis','P4_normal','P4_synthesis','full_regression','inputs_stable']
    stages={n:{'status':'PASS'} for n in names};checks['all_required']=verdict(stages)=='PASS'
    for status in ['SKIP','DIRTY','FAIL']:
        checks['gate_'+status]=verdict(dict(stages,dependency_preflight={'status':status}))!='PASS'
    checks['missing_stage']=verdict({})!='PASS'
    with tempfile.TemporaryDirectory() as d:
        f=Path(d)/'input';f.write_text('a\nb\n');h=gate.digest(f);f.write_bytes(b'a\r\nb\r\n');checks['crlf_normalization']=gate.digest(f)==h
        f.write_text('changed');checks['content_changed']=gate.digest(f)!=h
        olddeps=gate.dependencies;oldtools=gate.versions;oldphysical=gate.physical_check
        mapping={'input':'h1'};tools={'simulation':'v1','synthesis':'v1'}
        gate.dependencies=lambda kind:dict(mapping);gate.versions=lambda:dict(tools);gate.physical_check=lambda:{'source_and_reports_match':True}
        artifact=Path(d)/'log';artifact.write_text('passed')
        receipt=Path(d)/'receipt.json';r={'verdict':'PASS','inputs_before':dict(mapping),'inputs_after':dict(mapping),'artifacts':{str(artifact):gate.digest(artifact)}};gate.save(receipt,r)
        base={'functional':dict(mapping),'physical':dict(mapping),'tools':dict(tools),'receipt':str(receipt),'receipt_sha256':gate.digest(receipt)}
        checks['real_check_clean']=gate.check(base)['status']=='PASS'
        mapping['input']='h2';checks['real_check_edit']=gate.check(base)['status']=='STALE'
        mapping.clear();checks['real_check_delete']=gate.check(base)['status']=='STALE'
        mapping.update(input='h1',new='h3');checks['real_check_add']=gate.check(base)['status']=='STALE'
        mapping.pop('new');tools['simulation']='v2';checks['tool_change']=not gate.check(base)['functional_evidence_valid'];tools['simulation']='v1'
        artifact.write_text('changed');checks['artifact_tamper']=gate.check(base)['status']=='STALE'
        gate.dependencies=olddeps;gate.versions=oldtools;gate.physical_check=oldphysical
    gate.save(AUDIT/'run/SELFTEST.json',{'checks':checks,'pass':sum(checks.values()),'fail':sum(not v for v in checks.values())})
    print(json.dumps(checks));return 0 if all(checks.values()) else 1

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--selftest',action='store_true');ap.add_argument('--skip-gate',action='store_true');ap.add_argument('--skip-p2',action='store_true');ap.add_argument('--skip-p4',action='store_true');a=ap.parse_args()
    if a.selftest:return selftest()
    out=AUDIT/'run/runs'/time.strftime('%Y%m%d_%H%M%S');out.mkdir(parents=True,exist_ok=False)
    env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',PYTHONIOENCODING='utf-8',MGLS_LICENSE_FILE='D:/software/Modelsim/LICENSE.TXT',LM_LICENSE_FILE='D:/software/Modelsim/LICENSE.TXT')
    ms=Path('D:/software/Modelsim/win64');report={'schema':'its.closure.run.v2','verdict':'RUNNING','official_equivalence':'NOT_PROVEN','stages':{},'inputs_before':gate.dependencies('functional'),'physical_inputs_before':gate.dependencies('physical'),'artifacts':{}}
    def command(argv,wd,log,timeout=600):
        with log.open('wb') as s:q=subprocess.run(list(map(str,argv)),cwd=wd,env=env,stdout=s,stderr=subprocess.STDOUT,timeout=timeout)
        report['artifacts'][str(log)]=gate.digest(log)
        if q.returncode:raise RuntimeError(f'Command failed ({q.returncode}): {log}')
        return log.read_text(errors='replace')
    def record(n,status,**detail):report['stages'][n]={'status':status,**detail};print(n,status,flush=True)
    try:
        report['tools']=gate.versions()
        # Existing receipt may be stale because runner changed. A complete new run requalifies functional evidence;
        # it does not requalify physical dependencies. Compare old physical snapshot before launching tests.
        old=json.loads(gate.BASE.read_text()) if gate.BASE.exists() else None
        if old and old['physical']!=report['physical_inputs_before']:raise RuntimeError('Physical dependencies changed; physical rerun required')
        physical=gate.physical_check();report['historical_physical']=physical
        if not physical['source_and_reports_match']:raise RuntimeError('Historical physical input/report mismatch')
        if old and old['tools']!=report['tools']:raise RuntimeError('Tool versions changed; requalification required')
        record('dependency_preflight','SKIP' if a.skip_gate else 'PASS',scope='New functional qualification; historical physical provenance only')
        for name,(module,count,marker) in SUITES.items():
            for mode in ['normal','synthesis']:
                key=name+'_'+mode
                if (name=='P2' and a.skip_p2) or (name=='P4' and a.skip_p4):record(key,'SKIP');continue
                wd=out/key;wd.mkdir();rom=wd/'03_verification/sim';rom.mkdir(parents=True)
                for f in (gate.REPO/'02_rtl/rtl').glob('*.hex'):shutil.copy2(f,rom/f.name)
                if name=='P2':
                    for f in ['p2_stim.hex','p2_sat.hex','p2_low.hex']:shutil.copy2(gate.FIXTURE/f,wd/f)
                sources=[gate.REPO/'02_rtl/rtl'/f for f in RTL]+[gate.FIXTURE/(module+'.sv')]
                command([ms/'vlib.exe','work'],wd,wd/'vlib.log')
                command([ms/'vlog.exe','-sv']+(['+define+SYNTHESIS'] if mode=='synthesis' else [])+sources,wd,wd/'compile.log')
                (wd/'run.do').write_text('onerror {quit -f -code 1}\nonbreak {quit -f -code 1}\nrun -all\nquit -f -code 0\n')
                text=command([ms/'vsim.exe','-c','work.'+module,'-do','run.do'],wd,wd/'simulation.log')
                ok=assess(name,text,0);record(key,'PASS' if ok else 'FAIL',log=str(wd/'simulation.log'))
                if not ok:raise RuntimeError('Incomplete/failed simulation '+key)
        full=out/'full_regression'
        command([sys.executable,gate.REPO/'03_verification/step12d_engineering/run_functional_closure.py','--evidence-dir',full,'--modelsim-bin',ms,'--license-file','D:/software/Modelsim/LICENSE.TXT'],gate.REPO,out/'full_regression.log',3600)
        result=json.loads((full/'FUNCTIONAL_CLOSURE.json').read_text(encoding='utf-8'))
        if result['status']!='PASS_FUNCTIONAL_ENGINEERING_CONTRACT':raise RuntimeError('Full regression not PASS')
        record('full_regression','PASS',result=str(full/'FUNCTIONAL_CLOSURE.json'))
        for f in full.rglob('*'):
            if f.is_file() and f.suffix in {'.log','.json'}:report['artifacts'][str(f)]=gate.digest(f)
    except Exception as e:
        report['error']=str(e);record('runner','FAIL',error=str(e))
    finally:
        report['inputs_after']=gate.dependencies('functional');report['physical_inputs_after']=gate.dependencies('physical')
        stable=report['inputs_before']==report['inputs_after'] and report['physical_inputs_before']==report['physical_inputs_after']
        record('inputs_stable','PASS' if stable else 'FAIL');report['verdict']=verdict(report['stages'])
        gate.save(out/'closure_run.json',report);gate.save(AUDIT/'run/closure_run.json',report)
    if report['verdict']=='PASS':
        gate.save(gate.BASE,{'functional':report['inputs_after'],'physical':report['physical_inputs_after'],'tools':report['tools'],'receipt':str(out/'closure_run.json'),'receipt_sha256':gate.digest(out/'closure_run.json'),'trust':'Local successful-run receipt; not a signature.'})
    print('OVERALL '+report['verdict'],flush=True);return 0 if report['verdict']=='PASS' else 1
if __name__=='__main__':sys.exit(main())
