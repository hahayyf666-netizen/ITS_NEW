"""Run repository-contained functional checks and discriminating negative controls.

Python 3 + PowerShell 7 + ModelSim + a C++17 compiler are required. Coefficient
files, vectors, testbenches, and native-reference source come from this checkout.
No physical implementation is launched. Every subprocess has a bounded timeout.
"""
from pathlib import Path
import argparse, hashlib, json, os, re, shutil, subprocess, sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
RTL = ['its_simple_ram.sv', 'its_input_cache_bank.sv', 'unified_p4_kernel.sv',
       'bounded_lfnst_engine.sv', 'unified_its_wrapper.sv', 'its_unified_submission_top.sv']
TESTS = [('unified_its_end_attribution_tb', 19), ('end_attribution_simultaneous_tb', 2),
         ('end_attribution_ordering_tb', 1), ('end_attribution_barrier_queue_tb', 1)]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--evidence-dir', type=Path, required=True)
    p.add_argument('--modelsim-bin', type=Path,
                   default=os.environ.get('ITS_MODELSIM_BIN', 'D:/software/Modelsim/win64'))
    p.add_argument('--license-file', default=os.environ.get('MGLS_LICENSE_FILE') or os.environ.get('LM_LICENSE_FILE'))
    p.add_argument('--compiler', default=os.environ.get('ITS_CXX') or shutil.which('g++') or
                   'D:/AMDDesignTools/2025.2/tps/mingw/10.0.0/win64.o/nt/bin/g++.exe')
    p.add_argument('--directed-only', action='store_true', help='Diagnostic mode, not complete qualification')
    args = p.parse_args()
    out = args.evidence_dir.resolve()
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', PYTHONIOENCODING='utf-8',
               ITS_MODELSIM_BIN=str(args.modelsim_bin.resolve()))
    if args.license_file:
        env.update(LM_LICENSE_FILE=args.license_file, MGLS_LICENSE_FILE=args.license_file)
    records = []
    inputs = [REPO/'02_rtl/rtl'/n for n in RTL]
    inputs += list((REPO/'03_verification/tb').glob('*.sv'))
    inputs += list(HERE.glob('*.py')) + list(HERE.glob('*.ps1')) + list((HERE/'profiles').glob('*.json'))
    inputs += list((REPO/'02_rtl/rtl').glob('*.hex'))
    inputs += list(HERE.glob('*.cpp'))
    inputs += list((REPO/'04_reference/VTM/source/Lib/CommonLib').glob('*.h'))
    inputs += list((REPO/'04_reference/VTM/source/Lib/CommonLib').glob('*.cpp'))
    inputs += [REPO/'03_verification/output/canonical_matrices.json']
    inputs += list((REPO/'05_audit/current/27/step12d_engineering').glob('*.json'))
    before = {x.relative_to(REPO).as_posix(): sha(x) for x in inputs}
    report = {'status': 'RUNNING', 'official_equivalence': 'NOT_PROVEN',
              'inputs_sha256': before, 'records': records, 'rtl_modified_by_runner': False,
              'negative_control_policy': 'Generated temporary mutants; compile failure is never a detected defect.'}

    def command(argv, wd, log, timeout=600):
        with log.open('wb') as stream:
            r = subprocess.run(list(map(str, argv)), cwd=wd, env=env,
                               stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
        if r.returncode:
            raise RuntimeError(f'Command exited {r.returncode}: {log.relative_to(out)}')

    try:
        for name in ['vlib.exe', 'vlog.exe', 'vsim.exe']:
            if not (args.modelsim_bin/name).is_file():
                raise RuntimeError(f'Missing ModelSim executable: {name}; use --modelsim-bin')
        original = (REPO/'02_rtl/rtl/unified_its_wrapper.sv').read_bytes()
        token = b' && !fill_end_pending_q'
        if original.count(token) != 1:
            raise RuntimeError('Ordering-barrier mutation point is not unique')
        mutant_dir = out/'mutants'; mutant_dir.mkdir()
        mutant = mutant_dir/'no_order_barrier.sv'
        mutant.write_bytes(original.replace(token, b''))
        old = REPO/'03_verification/regression_baseline/081efa6/02_rtl/rtl/unified_its_wrapper.sv'
        jobs = [('current', module, n) for module, n in TESTS]
        jobs += [('no_order_barrier', TESTS[2][0], 1), ('no_order_barrier', TESTS[3][0], 1),
                 ('frozen_no_early_end', TESTS[0][0], 19)]
        for variant, module, count in jobs:
            for mode in ['normal', 'synthesis']:
                wd = out/'directed'/variant/mode/module; wd.mkdir(parents=True)
                rom = wd/'03_verification/sim'; rom.mkdir(parents=True)
                for n in ['rom_coeffs.hex', 'lfnst_coeffs.hex', 'lfnst_packed_coeffs.hex']:
                    shutil.copy2(REPO/'02_rtl/rtl'/n, rom/n)
                sources = [REPO/'02_rtl/rtl'/n for n in RTL]
                if variant != 'current':
                    sources[4] = mutant if variant == 'no_order_barrier' else old
                command([args.modelsim_bin/'vlib.exe', 'work'], wd, wd/'vlib.log')
                compile_args = [args.modelsim_bin/'vlog.exe', '-sv']
                if mode == 'synthesis': compile_args += ['+define+SYNTHESIS']
                command(compile_args + sources + [REPO/'03_verification/tb'/f'{module}.sv', '-l', 'compile.log'],
                        wd, wd/'compile_console.log')
                compilation = (wd/'compile.log').read_text(errors='replace')
                if 'Errors: 0, Warnings: 0' not in compilation:
                    raise RuntimeError(f'Compile diagnostics: {variant}/{mode}/{module}')
                (wd/'run.do').write_bytes(b'onerror {quit -f -code 1}\nonbreak {quit -f}\nrun -all\nquit -f\n')
                command([args.modelsim_bin/'vsim.exe', '-c', f'work.{module}', '-l', 'simulation.log', '-do', 'run.do'],
                        wd, wd/'console.log')
                log = (wd/'simulation.log').read_text(errors='replace')
                pairs = re.findall(r'(?m)^# CASE ([CS]\d+[a-z]?)[^\s]* RESULT=(PASS|FAIL)\s*$', log)
                if len(pairs) != count or len(dict(pairs)) != count or 'GLOBAL_TIMEOUT' in log:
                    raise RuntimeError(f'Incomplete case results: {variant}/{mode}/{module}')
                if 'Errors: 0, Warnings: 0' not in log or re.search(r'\*\* (?:Fatal|Error):', log):
                    raise RuntimeError('Simulator error, not a valid negative-control detection')
                if variant == 'current':
                    ok = all(v == 'PASS' for _, v in pairs)
                    if module == TESTS[2][0]: ok &= 'COVER_BIND_BARRIER blocked=1' in log
                    if module == TESTS[3][0]: ok &= 'COVER_BIND_RESUME resumed=1' in log
                elif variant == 'no_order_barrier':
                    ok = all(v == 'FAIL' for _, v in pairs)
                    if module == TESTS[2][0]:
                        ok &= 'COVER_BIND_BARRIER blocked=0' in log and log.count('bad_beats=4') == 2
                else:
                    oldpass = {'C01','C02','C03','C04','C08b','C09a','C11a','C11b'}
                    ok = all(v == ('PASS' if c in oldpass else 'FAIL') for c,v in pairs)
                rec = {'variant': variant, 'mode': mode, 'test': module, 'cases': dict(pairs),
                       'expected_outcome_matched': bool(ok), 'log': (wd/'simulation.log').relative_to(out).as_posix(),
                       'log_sha256': sha(wd/'simulation.log')}
                records.append(rec)
                print(json.dumps(rec), flush=True)
                if not ok: raise RuntimeError(f'Unexpected test outcome: {variant}/{mode}/{module}')
        if not args.directed_only:
            command(['pwsh', '-NoProfile', '-File', HERE/'qualify_full_spatial_repair.ps1',
                     '-EvidenceDir', out/'qualification', '-Compiler', args.compiler],
                    REPO, out/'qualification_console.log', timeout=2400)
            q = json.loads((out/'qualification/REPAIR_FUNCTIONAL_QUALIFICATION.json').read_text(encoding='utf-8-sig'))
            if q['status'] != 'PASS_FULL_SPATIAL_REPAIR_FUNCTIONAL_QUALIFICATION':
                raise RuntimeError('Full regression status missing')
            report['full_qualification'] = q
        if any(sha(REPO/n) != h for n,h in before.items()):
            raise RuntimeError('Functional source changed during qualification')
        report['status'] = 'PASS_DIRECTED_ONLY' if args.directed_only else 'PASS_FUNCTIONAL_ENGINEERING_CONTRACT'
        report['official_closure'] = 'OPEN_PENDING_SPEC_CLARIFICATIONS'
    except Exception as e:
        report.update(status='FAIL', error=str(e))
        raise
    finally:
        (out/'FUNCTIONAL_CLOSURE.json').write_text(json.dumps(report, indent=2)+'\n', encoding='utf-8')
    print(report['status'], flush=True)

if __name__ == '__main__':
    main()
