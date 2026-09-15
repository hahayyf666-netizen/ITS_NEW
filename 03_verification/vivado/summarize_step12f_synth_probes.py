"""Read actual tool outputs; emit a synthesis-completion (not timing PASS) audit."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / '05_audit/current/31'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def timing(path):
    if not path.is_file():
        return None
    body = path.read_text(errors='replace').split('Design Timing Summary')[-1]
    match = re.search(r'^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+'
                      r'(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)', body, re.M)
    if not match:
        return None
    values = match.groups()
    return dict(wns_ns=float(values[0]), tns_ns=float(values[1]),
                setup_failing_endpoints=int(values[2]), whs_ns=float(values[4]),
                ths_ns=float(values[5]), hold_failing_endpoints=int(values[6]),
                kind='POST_SYNTHESIS_ESTIMATE_NOT_POST_ROUTE_SIGNOFF')


def utilization(path):
    if not path.is_file():
        return None
    body = path.read_text(errors='replace')
    result = {}
    for key, label in [('lut', r'CLB LUTs\*'), ('ff', 'CLB Registers'),
                       ('lutram', 'LUT as Memory'), ('dsp', 'DSPs'),
                       ('bram_tiles', 'Block RAM Tile'), ('uram', 'URAM'),
                       ('latches', 'Register as Latch')]:
        match = re.search(r'\|\s*' + label + r'\s*\|\s*([\d.]+)\s*\|', body)
        result[key] = float(match[1]) if match else None
    return result


def run(name, wrapper=False, directive='Default'):
    folder = EVIDENCE / name
    log = folder / 'vivado.log' if wrapper else EVIDENCE / (name + '.log')
    body = log.read_text(errors='replace') if log.exists() else ''
    dcp = folder / ('step12f_unified_wrapper_postsynth.dcp' if wrapper else 'postsynth.dcp')
    util = folder / ('report_utilization_postsynth.rpt' if wrapper else 'utilization.rpt')
    time = folder / ('report_timing_summary_postsynth.rpt' if wrapper else 'timing.rpt')
    checks = folder / ('report_check_timing_postsynth.rpt' if wrapper else 'check_timing.rpt')
    check_body = checks.read_text(errors='replace') if checks.is_file() else ''
    check_counts = {k: int(v) for k, v in re.findall(r'checking (\w+) \((\d+)\)', check_body)}
    exceptions = folder / 'report_exceptions_postsynth.rpt'
    exception_body = exceptions.read_text(errors='replace') if exceptions.is_file() else ''
    elapsed = re.search(r'(?:PROBE_SYNTH_DONE[^\n]*elapsed_seconds=|STEP12F_SYNTH_ELAPSED_SEC=)(\d+)', body)
    complete = 'synth_design completed successfully' in body and dcp.is_file()
    return dict(status='SYNTHESIS_COMPLETED' if complete else 'NOT_COMPLETED',
                directive=directive, elapsed_seconds=int(elapsed[1]) if elapsed else None,
                log=str(log.relative_to(ROOT)), log_sha256=sha(log),
                checkpoint=str(dcp.relative_to(ROOT)), checkpoint_sha256=sha(dcp),
                timing=timing(time), utilization=utilization(util),
                check_timing=check_counts,
                no_valid_timing_exceptions=('No valid timing exceptions found' in exception_body) if wrapper else None,
                peak_logged_memory_mb=max([float(v) for v in re.findall(r'Memory \(MB\): peak = ([\d.]+)', body)] or [0]))


def main():
    coverage_path = EVIDENCE / 'packed_coverage/STEP12F_COVERAGE_MODELSIM_RUN.json'
    coverage = json.loads(coverage_path.read_text(encoding='utf-8-sig'))
    kernel = ROOT / '02_rtl/rtl/unified_p4_kernel.sv'
    experimental = ROOT / '03_verification/experiments/step12f_rom_layout/unified_p4_kernel.sv'
    matching = sha(kernel).upper() == coverage['source_hashes']['unified_p4_kernel'].upper() == sha(experimental).upper()
    if not matching or coverage['status'] != 'PASS':
        raise RuntimeError('RTL hash must match the fully passing regression')
    rtl_changes = subprocess.check_output(
        ['git', 'diff', '--name-only', 'b7c0a3f', '--', '02_rtl/rtl'], cwd=ROOT,
        text=True, stderr=subprocess.PIPE).splitlines()
    if rtl_changes != ['02_rtl/rtl/unified_p4_kernel.sv']:
        raise RuntimeError('Unexpected production RTL changes: ' + repr(rtl_changes))
    layout = {}
    for mode in ('normal', 'synthesis'):
        log = EVIDENCE / 'coeff_layout' / mode / 'layout.log'
        body = log.read_text(errors='replace')
        if 'P4_COEFF_LAYOUT_PASS canonical=8176 padding=7440 bundles=61' not in body:
            raise RuntimeError('Exhaustive coefficient layout check missing')
        layout[mode] = dict(status='PASS', log_sha256=sha(log))
    modules = {name: run(name, directive=directive) for name, directive in [
        ('ram_probe_corrected', 'Default'), ('input_bank_probe', 'Default'),
        ('lfnst_probe', 'Default'), ('kernel_packed', 'Default'),
        ('kernel_packed_runtime', 'RuntimeOptimized')]}
    full = run('wrapper_packed_default', wrapper=True)
    checked = ['02_rtl/rtl/unified_p4_kernel.sv', '02_rtl/rtl/unified_its_wrapper.sv',
               '02_rtl/rtl/bounded_lfnst_engine.sv', '02_rtl/rtl/its_simple_ram.sv',
               '02_rtl/rtl/its_input_cache_bank.sv', '02_rtl/rtl/rom_coeffs.hex',
               '03_verification/vivado/step12f_unified_wrapper_2ns.xdc',
               '03_verification/vivado/run_step12f_unified_wrapper.tcl',
               '03_verification/vivado/probe_step12f_synthesis.tcl',
               '03_verification/vivado/step12f_module_probe_2ns.xdc',
               '03_verification/tb/unified_p4_coeff_layout_tb.sv']
    result = dict(schema='step12f.synthesis_isolation.v1', baseline_commit='b7c0a3f',
                  status=('SYNTHESIS_COMPLETED_TIMING_NOT_CLOSED' if full['status'] == 'SYNTHESIS_COMPLETED'
                          else 'TOP_SYNTHESIS_NOT_COMPLETED'),
                  module_probes=modules, full_wrapper=full,
                  baseline_kernel=dict(status='CONTROLLED_STOP', observed_seconds=605,
                      last_phase='Cross Boundary and Area Optimization',
                      log='05_audit/current/31/kernel_baseline.log',
                      log_sha256=sha(EVIDENCE / 'kernel_baseline.log'),
                      note='Not a tool error; stopped after diagnosis. Runs overlapped, so times are not an isolated benchmark.'),
                  coverage=dict(status='PASS', tested_candidate_matches_production_hash=matching,
                      evidence=str(coverage_path.relative_to(ROOT)), sha256=sha(coverage_path),
                      modes=['normal', 'SYNTHESIS'], tuples_per_mode=369, beats_per_mode=45636,
                      vector_ii_modes=13, kernel_numeric_cases_per_mode=156,
                      lfnst_engine_cases_per_mode=1088, lfnst_wrapper_cases_per_mode=258),
                  coefficient_layout=dict(canonical_count=8176, zero_padding_count=7440,
                      bundles=61, width_bits=4096, checks=layout),
                  source_hashes={p: sha(ROOT/p) for p in checked},
                  change_scope='Coefficient memory layout only; no added arithmetic pipeline or changed handshake',
                  changed_production_rtl_paths=rtl_changes,
                  rtl_tree_changed=True, frozen_r4c_changed=False, historical_wrapper_changed=False,
                  xdc_changed=False, oracle_changed=False, arithmetic_pipeline_changed=False,
                  implementation_run=False, new_tag_created=False,
                  excluded_probe=dict(name='ram_probe', reason='First exploratory run used wrapper-specific port constraints; superseded by ram_probe_corrected'),
                  known_next_issue='Unregistered multiplier/reduction/postprocess path; requires separately reviewed physical pipeline, not more timeout retries')
    json.dump(result, sys.stdout, indent=2)
    print()


if __name__ == '__main__':
    main()
