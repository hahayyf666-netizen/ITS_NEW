"""Read-only review of the frozen submission package and published evidence.

Writes only review/delivery artifacts. Does not run synthesis, simulation or implementation.
"""
import hashlib
import json
import re
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
FUNCTIONAL = ROOT / '05_audit/current/101_final_submission_20261006'
SOURCE = 'cb65bbf1cc2dc9e5e649b2fe8b8affc67435c5a7'
DUT_SOURCE = '9b33d9f62de49f022765cd594704353edeaa352c'
EVIDENCE = '70153eb14d62801531386af35075c770e1bf51f4'
PROFILE_SHA = 'FEA3ACB18C5C35EB0FD8A8DBF533C3A6BE7536BCC8EF5FDB87135DF512643746'
checks = []


def sha(data):
    return hashlib.sha256(data).hexdigest().upper()


def git(*args):
    result = subprocess.run(['git', '-c', f'safe.directory={ROOT.as_posix()}',
                             '-C', str(ROOT), *args], capture_output=True, check=True)
    return result.stdout.decode('utf-8').strip()


def check(name, passed, details):
    checks.append({'name': name, 'status': 'PASS' if passed else 'FAIL', 'details': details})


def load(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def hash_matches(data, expected):
    # The evidence explicitly distinguishes Windows working bytes from Git LF bytes.
    lf = data.replace(b'\r\n', b'\n')
    return expected.upper() in {sha(data), sha(lf), sha(lf.replace(b'\n', b'\r\n'))}


def blobs(expressions):
    result = subprocess.run(['git', '-c', f'safe.directory={ROOT.as_posix()}',
                             '-C', str(ROOT), 'cat-file', '--batch'],
                            input=('\n'.join(expressions) + '\n').encode(),
                            capture_output=True, check=True)
    data = result.stdout
    offset = 0
    records = []
    for expression in expressions:
        end = data.index(b'\n', offset)
        header = data[offset:end].decode().split()
        if len(header) != 3 or header[1] != 'blob':
            raise RuntimeError(f'Expected blob: {expression}: {header}')
        size = int(header[2])
        start = end + 1
        records.append((header[0], data[start:start + size]))
        offset = start + size + 1
    return records


head = git('rev-parse', 'HEAD')
manifest = load(FUNCTIONAL / 'FINAL_SUBMISSION_MANIFEST.json')
package = load(FUNCTIONAL / 'package/PACKAGE_MANIFEST.json')
publication = load(FUNCTIONAL / 'PUBLICATION_MANIFEST.json')
sim = load(FUNCTIONAL / '05_modelsims/STEP12F_COVERAGE_MODELSIM_RUN.json')
frozen_diff = git('diff', '--name-only', SOURCE, head, '--', '02_rtl', '03_verification')
check('tested_source_preserved', not frozen_diff and manifest['tested_source_commit'] == SOURCE,
      {'tested_source_commit': SOURCE, 'reviewed_head': head, 'changed_source_paths': frozen_diff.splitlines()})
dut_diff = git('diff', '--name-only', DUT_SOURCE, head, '--', '02_rtl')
check('physical_dut_preserved', not dut_diff, {'dut_source_commit': DUT_SOURCE, 'changed_paths': dut_diff.splitlines()})
check('checkpoint_stages', manifest['status'] == 'SUBMISSION_FUNCTIONAL_FREEZE_READY'
      and len(manifest['stages']) == 5 and all(s['exit_code'] == 0 for s in manifest['stages']), manifest['stages'])

profile_path = '03_verification/step12d_engineering/profiles/contest_engineering_vtm10_sat10_v2.json'
profile_bytes = (ROOT / profile_path).read_bytes()
profile = json.loads(profile_bytes)
check('frozen_sat10_profile', sha(profile_bytes.replace(b'\r\n', b'\n')) == PROFILE_SHA
      and profile['final10']['default'] == 'SAT10' and profile['final10']['range'] == [-512, 511]
      and profile['official_equivalence'] == 'NOT_PROVEN', {'canonical_sha256': PROFILE_SHA})

archive = FUNCTIONAL / 'package/source.zip'
archive_sha = sha(archive.read_bytes())
check('archive_identity', archive_sha == package['archive_sha256'] and package['tested_source_commit'] == SOURCE,
      {'sha256': archive_sha, 'tested_source_commit': package['tested_source_commit'], 'top': package['top']})
inventory_failures = []
archive_eol_differences = 0
with zipfile.ZipFile(archive) as z:
    names = [n for n in z.namelist() if not n.endswith('/')]
    inventory = {f['path']: f['sha256'] for f in package['files']}
    same_members = len(names) == len(set(names)) and set(names) == set(inventory)
    source_blobs = blobs([f'{SOURCE}:{path}' for path in inventory])
    for (path, expected), (blob_id, content) in zip(inventory.items(), source_blobs):
        zipped = z.read(path)
        if zipped != content and zipped.replace(b'\r\n', b'\n') == content.replace(b'\r\n', b'\n'):
            archive_eol_differences += 1
        if sha(zipped) != expected or zipped.replace(b'\r\n', b'\n') != content.replace(b'\r\n', b'\n'):
            inventory_failures.append(path)
check('complete_archive_inventory', same_members and not inventory_failures,
      {'files': len(inventory), 'all_match_tested_git_contents': not inventory_failures,
       'git_archive_eol_only_differences': archive_eol_differences, 'failures': inventory_failures})

publication_failures = []
published = blobs([f"{EVIDENCE}:{f['path']}" for f in publication['files']])
for entry, (blob_id, content) in zip(publication['files'], published):
    if blob_id != entry['git_blob'] or sha(content) != entry['published_content_sha256']:
        publication_failures.append(entry['path'])
check('published_evidence_hashes', not publication_failures,
      {'files': len(published), 'failures': publication_failures})

log_failures = []
for record in sim['compile_records'] + sim['command_records']:
    path = FUNCTIONAL / '05_modelsims' / f"{record['mode']}_{record['log']}"
    data = path.read_bytes()
    text = data.decode('utf-8-sig')
    if record['exit_code'] != 0 or not hash_matches(data, record['log_sha256']):
        log_failures.append(str(path.relative_to(ROOT)))
    if record.get('pass_marker') and record['pass_marker'] not in text:
        log_failures.append(str(path.relative_to(ROOT)) + ': marker missing')
    if record in sim['compile_records'] and re.search(r'\*\* (?:Error|Warning):', text):
        log_failures.append(str(path.relative_to(ROOT)) + ': compile error/warning')
check('actual_execution_logs', sim['status'] == 'PASS' and len(sim['command_records']) == 36
      and len(sim['compile_records']) == 2 and not log_failures,
      {'simulations': len(sim['command_records']), 'compiles': len(sim['compile_records']), 'failures': log_failures})
expected_gates = {
    'gate_b_kernel_numeric': 'PASS_156_CASES', 'gate_f_vector_ii': 'PASS_13_MODES',
    'submission_top_full_gate_c': 'PASS_369_CASES_45636_BEATS',
    'submission_top_lfnst_specialty': 'PASS_388_CASES_6724_BEATS',
    'submission_top_protocol': 'PASS_END_MARKERS_RESET_INPUT_GAPS_ILLEGAL_STICKY',
    'sat10_adapter_exhaustive': 'PASS_65536_VALUES', 'lfnst_engine_specialty': 'PASS_1088_CASES',
    'p4_stage0_issue_contract': 'PASS_16_N4_VECTORS_SLOT_RELEASE',
}
check('normal_synthesis_gates', {r['mode'] for r in sim['runs']} == {'normal', 'synthesis'}
      and all(r[k] == v for r in sim['runs'] for k, v in expected_gates.items()), expected_gates)

top = (ROOT / '02_rtl/rtl/its_unified_submission_top.sv').read_text()
compile_commands = [r['command'] for r in sim['compile_records']]
check('explicit_submission_entry', package['top'] == 'its_unified_submission_top'
      and '.FINAL_SATURATE(1)' in top and 'output logic [39:0] it_data_out' in top
      and all('its_unified_submission_top.sv' in c and 'rtl\\its_top.v' not in c for c in compile_commands),
      {'module': 'its_unified_submission_top', 'adapter': 'SAT10', 'legacy_top_compiled': False})
negative = load(FUNCTIONAL / 'PROFILE_NEGATIVE_RESULT.json')
check('wrong_profile_rejected', negative.get('actual_exit') == 1
      and negative.get('status') == 'PASS_REJECTED_BEFORE_MODELSIM'
      and negative.get('unexpected_evidence_created') is False, negative)

physical_runs = []
physical_hash_failures = []
physical_source_identities = []
for folder, filename in [('99_p9_primary_v_return_20261005', 'P9_PRIMARY_V_RETURN_PHYSICAL_MANIFEST.json'),
                         ('100_p9_primary_v_replay_20261006', 'P9_PRIMARY_V_REPLAY_MANIFEST.json')]:
    directory = ROOT / '05_audit/current' / folder
    authority = load(directory / filename)
    timing, impl = authority['timing'], authority['implementation']
    source_records = {p: h for p, h in authority['source_hashes'].items()
                      if p.startswith('02_rtl/') or p.startswith('03_verification/vivado/') or p == profile_path}
    for (path, identity), (blob_id, content) in zip(source_records.items(), blobs([f'{head}:{p}' for p in source_records])):
        if isinstance(identity, dict):
            working = (ROOT / path).read_bytes()
            working_blob = hashlib.sha1(b'blob ' + str(len(working)).encode() + b'\0' + working).hexdigest()
            lf_working = working.replace(b'\r\n', b'\n')
            lf_blob = hashlib.sha1(b'blob ' + str(len(lf_working)).encode() + b'\0' + lf_working).hexdigest()
            matched = sha(working) == identity['sha256'] and working.replace(b'\r\n', b'\n') == content.replace(b'\r\n', b'\n')
            recorded_blob_class = ('COMMIT_GIT_BLOB' if blob_id == identity['git_blob'] else
                                   'WORKING_BYTE_GIT_OBJECT_HASH' if working_blob == identity['git_blob'] else
                                   'LF_NORMALIZED_GIT_OBJECT_HASH' if lf_blob == identity['git_blob'] else
                                   'UNRESOLVED')
            matched &= recorded_blob_class != 'UNRESOLVED'
            physical_source_identities.append({'run': folder, 'path': path,
                                               'actual_commit_git_blob': blob_id,
                                               'working_tree_sha256': sha(working),
                                               'historical_git_blob_field': identity['git_blob'],
                                               'historical_field_class': recorded_blob_class})
        else:
            matched = hash_matches(content, identity)
        if not matched:
            physical_hash_failures.append(folder + ':' + path)
    raw_setup = (directory / 'report_timing_summary_postroute.rpt').read_text()
    raw_hold = (directory / 'report_timing_hold_summary_postroute.rpt').read_text()
    setup_match = re.search(r'Setup\s*:\s*0\s+Failing Endpoints,\s*Worst Slack\s+0\.001ns,\s*Total Violation\s+0\.000ns', raw_setup)
    hold_match = re.search(r'Hold\s*:\s*0\s+Failing Endpoints,\s*Worst Slack\s+0\.011ns,\s*Total Violation\s+0\.000ns', raw_hold)
    good = bool(setup_match and hold_match) and impl['fully_routed'] and impl['routing_errors'] == 0 and impl['drc_errors'] == 0
    good &= all(timing[k] == 0 for k in ['setup_tns_ns', 'setup_failing_endpoints', 'hold_ths_ns', 'hold_failing_endpoints', 'unconstrained_internal_endpoints', 'valid_timing_exceptions'])
    physical_runs.append({'authority': f'05_audit/current/{folder}/{filename}', 'raw_reports_match': bool(setup_match and hold_match),
                          'pass': good, 'timing': timing, 'pid': impl.get('pid')})
check('two_fresh_physical_runs', all(r['pass'] for r in physical_runs) and not physical_hash_failures,
      {'runs': physical_runs, 'source_hash_failures': physical_hash_failures,
       'source_identities': physical_source_identities})

result = {
    'status': 'FINAL_RELEASE_REVIEW_PASS' if all(c['status'] == 'PASS' for c in checks) else 'FAIL_STOP',
    'reviewed_evidence_commit': EVIDENCE, 'reviewed_head': head, 'tested_source_commit': SOURCE,
    'DUT_functional_source_commit': DUT_SOURCE, 'profile': profile['profile_name'],
    'profile_sha256': PROFILE_SHA, 'source_zip_sha256': archive_sha,
    'review_method': 'Fresh source and raw-artifact review; no new simulator or implementation run',
    'checks': checks, 'official_equivalence': 'NOT_PROVEN',
    'package_timing': 'NOT_EVALUATED', 'nominal_setup_margin_ns': 0.001,
}
(HERE / 'FINAL_RELEASE_REVIEW.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
if result['status'] == 'FINAL_RELEASE_REVIEW_PASS':
    components = {
        'source.zip': archive.read_bytes(),
        'PACKAGE_MANIFEST.json': (FUNCTIONAL / 'package/PACKAGE_MANIFEST.json').read_bytes(),
        'FINAL_DELIVERY.md': (ROOT / '01_docs/current/FINAL_DELIVERY.md').read_bytes(),
        'FINAL_RELEASE_REVIEW.md': (HERE / 'FINAL_RELEASE_REVIEW.md').read_bytes(),
        'FINAL_RELEASE_REVIEW.json': (HERE / 'FINAL_RELEASE_REVIEW.json').read_bytes(),
        'CORE_TIMING_REPORT.md': (ROOT / '05_audit/current/100_p9_primary_v_replay_20261006/P9_PRIMARY_V_REPLAY_REPORT.md').read_bytes(),
    }
    delivery = {
        'status': 'FROZEN_SAT10_ENGINEERING_DELIVERY', 'top': package['top'],
        'tested_source_commit': SOURCE, 'functional_evidence_commit': EVIDENCE,
        'DUT_source_commit': DUT_SOURCE, 'reviewed_integration_commit': head,
        'profile': profile['profile_name'], 'canonical_profile_sha256': PROFILE_SHA,
        'functional': 'PASS', 'registered_neighbor_nominal_500mhz': 'PASS_TWO_FRESH_RUNS',
        'official_equivalence': 'NOT_PROVEN', 'package_timing': 'NOT_EVALUATED',
        'files': {name: {'sha256': sha(content), 'bytes': len(content)} for name, content in components.items()},
        'public_functional_evidence': f'https://github.com/hahayyf666-netizen/ITS_NEW/tree/{EVIDENCE}/05_audit/current/101_final_submission_20261006',
        'public_physical_evidence': f'https://github.com/hahayyf666-netizen/ITS_NEW/tree/{EVIDENCE}/05_audit/current/100_p9_primary_v_replay_20261006',
    }
    metadata = (json.dumps(delivery, ensure_ascii=False, indent=2) + '\n').encode()
    (HERE / 'DELIVERY_MANIFEST.json').write_bytes(metadata)
    components['DELIVERY_MANIFEST.json'] = metadata
    bundle = HERE / 'ITS_SAT10_FINAL_DELIVERY.zip'
    with zipfile.ZipFile(bundle, 'w') as z:
        for name, content in components.items():
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 6, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            z.writestr(info, content)
    (HERE / 'DELIVERY_ARCHIVE_SHA256.txt').write_text(sha(bundle.read_bytes()) + '  ITS_SAT10_FINAL_DELIVERY.zip\n', encoding='utf-8')
print(json.dumps({'status': result['status'], 'checks': len(checks),
                  'failed_checks': [c['name'] for c in checks if c['status'] != 'PASS']}, ensure_ascii=False, indent=2))
raise SystemExit(0 if result['status'] == 'FINAL_RELEASE_REVIEW_PASS' else 1)
