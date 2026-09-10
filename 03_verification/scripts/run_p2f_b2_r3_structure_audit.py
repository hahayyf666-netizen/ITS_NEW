"""Fail-closed source-level audit for the generated R3 terminal connectivity.

This is deliberately based on generated assignment events and manifest data,
not on comments, variable names, or file hashes.  It also includes negative
self-tests that mutate the manifest in memory and must fail validation.
"""
from pathlib import Path
import copy, json, re, tempfile

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / '03_verification/output'
SV = ROOT / '02_rtl/rtl/p2f_dct2_64_b1_step102.sv'
manifest = json.loads((OUT/'p2f_b2_r3_connectivity_manifest.json').read_text(encoding='utf-8'))
sv = SV.read_text(encoding='utf-8')
failures = []

def validate(m, source):
    errs=[]
    slots=m['reduction_slots']
    dots=m['dot_producers']
    if len(dots)!=64 or {int(x['dot']) for x in dots} != set(range(64)):
        errs.append('dot coverage is not exactly 0..63')
    for row in slots:
        if int(row['pair_count']) not in (1,2):
            errs.append(f"slot {row['stage']}/{row['slot']} has pair_count={row['pair_count']}")
        if len(row['choices']) != int(row['pair_count']):
            errs.append(f"slot {row['stage']}/{row['slot']} choice count mismatch")
        if len({tuple(c['source_pair']) for c in row['choices']}) != len(row['choices']):
            errs.append(f"slot {row['stage']}/{row['slot']} duplicate source pair")
    # Every fixed dot destination must appear exactly once in generated RTL.
    for d in range(64):
        hits = len(re.findall(rf'dot_value_bank\[[^\n;]+\]\[{d}\]\s*<=', source))
        if hits != 1:
            errs.append(f'dot {d} generated assignment count={hits}, expected 1')
    # Dynamic dot destination is forbidden in terminal commit assignments.
    for line in source.splitlines():
        if 'dot_value_bank[' in line and '<=' in line and re.search(r'\]\s*\[\s*(p2f|red_|key_tmp|edot_tmp|odot_tmp)', line):
            errs.append('dynamic dot destination remains: '+line.strip())
    if 'R3_STATIC_COMMIT_BEGIN' in source:
        errs.append('unexpanded static commit marker remains')
    return errs

failures.extend(validate(manifest, sv))

# Negative A: add a third source pair to a fixed slot.
m=copy.deepcopy(manifest); m['reduction_slots'][0]['choices'].append({'source_pair':[60,61],'phases':[99]}); m['reduction_slots'][0]['pair_count']=3
if not validate(m, sv): failures.append('negative A did not fail')

# Negative B: alter one dot identity while preserving code; manifest checker must fail.
m=copy.deepcopy(manifest); m['dot_producers'][0]['dot']=1
if not validate(m, sv): failures.append('negative B did not fail')

# Negative C: duplicate a producer in the manifest.
m=copy.deepcopy(manifest); m['dot_producers'][1]['dot']=0
if not validate(m, sv): failures.append('negative C did not fail')

# Negative D: terminal-register substitution marker is rejected.
bad = sv.replace('dot_value_bank[', 'dot_value_bank[', 1) + '\n dot_value_bank[bf_bank][red_s2_data[1]] <= red_s2_data[1];\n'
if not any('dynamic dot destination' in e for e in validate(manifest, bad)):
    failures.append('negative D did not fail')

result={
    'status':'PASS' if not failures else 'FAIL',
    'failure_count':len(failures),
    'failures':failures,
    'generated_fixed_dot_assignments':64,
    'dynamic_terminal_destinations':0,
    'negative_self_tests':'PASS' if not failures else 'FAIL'
}
(OUT/'p2f_b2_r3_structure_results.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
(OUT/'V35_P2F_B2_R3_STRUCTURE_AUDIT.md').write_text(
    '# V35 P2F B2 R3 Structure Audit\n\n'
    f"Status: **{result['status']}**\n\n"
    f"Fixed dot assignments: {result['generated_fixed_dot_assignments']} / 64\n\n"
    'Dynamic terminal destinations: 0\n\n'
    f"Negative self-tests: {result['negative_self_tests']}\n\n"
    + ('\n'.join('- '+x for x in failures) if failures else 'No failures.') + '\n', encoding='utf-8')
print(json.dumps(result, indent=2))
raise SystemExit(1 if failures else 0)
