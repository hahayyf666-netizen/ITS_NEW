"""Freeze Step12D engineering-profile Gate A evidence.

This batch deliberately separates official statements from engineering
bindings.  It creates a new evidence set under current/27 and never rewrites
the historical Step12D-PRE STOP records under current/26.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
OLD = ROOT / "05_audit" / "current" / "26" / "step12d_pre"
OUT = ROOT / "05_audit" / "current" / "27" / "step12d_engineering"
CANONICAL = ROOT / "03_verification" / "output" / "canonical_matrices.json"
VTM_ROOT = ROOT / "04_reference" / "VTM" / "source" / "Lib"
EMIT = "--emit" in sys.argv
ARTIFACT_TEXT: dict[str, str] = {}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest().upper()


def source_line(path: Path, needle: str) -> int:
    for i, text in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if needle in text:
            return i
    raise AssertionError(f"source marker not found: {path}:{needle}")


def source_line_after(path: Path, needle: str, anchor: str) -> int:
    """Locate a marker after a specific function/section anchor.

    TrQuant.cpp contains several shift_1st declarations.  For audit evidence
    we must point at the inverse xIT declaration, not the earlier forward path.
    """
    lines = path.read_text(encoding="utf-8").splitlines()
    anchor_line = None
    for i, text in enumerate(lines, 1):
        if anchor in text:
            anchor_line = i
            break
    if anchor_line is None:
        raise AssertionError(f"anchor not found: {path}:{anchor}")
    for i in range(anchor_line, len(lines) + 1):
        if needle in lines[i - 1]:
            return i
    raise AssertionError(f"marker not found after anchor: {path}:{needle}")


def write(name: str, value: Any) -> None:
    text = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    if EMIT:
        ARTIFACT_TEXT[name] = text
    else:
        (OUT / name).write_text(text, encoding="utf-8")


def git_head() -> str:
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()


def shape_tuple(text: str) -> tuple[int, int]:
    w, h = text.lower().split("x")
    return int(w), int(h)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    old_legal = json.loads((OLD / "LEGAL_TRANSFORM_MATRIX.json").read_text(encoding="utf-8"))
    canonical = json.loads(CANONICAL.read_text(encoding="utf-8"))

    dct2_shapes = [shape_tuple(x) for x in old_legal["official_shape_support"]["DCT2"]]
    dct8_shapes = {shape_tuple(x) for x in old_legal["official_shape_support"]["DCT8"]}
    dst7_shapes = {shape_tuple(x) for x in old_legal["official_shape_support"]["DST7"]}
    lfnst16_shapes = [shape_tuple(x) for x in old_legal["lfnst_shape_support"]["nTrs16"]]
    lfnst48_shapes = [shape_tuple(x) for x in old_legal["lfnst_shape_support"]["nTrs48"]]

    trquant = VTM_ROOT / "CommonLib" / "TrQuant.cpp"
    emt = VTM_ROOT / "CommonLib" / "TrQuant_EMT.cpp"
    typedef = VTM_ROOT / "CommonLib" / "TypeDef.h"
    sps = VTM_ROOT / "CommonLib" / "SequenceParameterSet.h"
    common_def = VTM_ROOT / "CommonLib" / "CommonDef.h"
    rom = VTM_ROOT / "CommonLib" / "Rom.h"
    for p in (trquant, emt, typedef, sps, common_def, rom):
        assert p.exists(), p

    qa_text = (
        "Only inverse transform is required; it_data_addr is full-TU raster order and "
        "only nonzero points are sent; attachment fill order has priority and VTM is "
        "the designated reference for missing algorithm details; vertical precedes "
        "horizontal and tr_type_hor/tr_type_ver select the corresponding axes; output "
        "is 10-bit two's complement; a following TU may be admitted back-to-back when "
        "it_data_in_req is high; clk/rst are required and reset is active-low asynchronous."
    )
    qa = {
        "schema": "step12d_engineering.official_expert_qa.v1",
        "source_id": "OFFICIAL_EXPERT_QA_USER_PROVIDED_TRANSCRIPT",
        "evidence_class": "official_answer_as_supplied_by_user",
        "provenance_note": "The transcript is recorded as supplied; it is not silently promoted to a normative standard clause.",
        "sha256_normalized_answer": hashlib.sha256(qa_text.encode("utf-8")).hexdigest().upper(),
        "confirmed_contracts": {
            "inverse_only": True,
            "input_address_semantics": "full_TU_raster_index; sparse nonzero data only",
            "fill_order_precedence": ["contest_attachment", "designated_VTM_reference"],
            "axis_order": "vertical_then_horizontal",
            "axis_selector_semantics": {
                "tr_type_hor": "horizontal_transform_type",
                "tr_type_ver": "vertical_transform_type",
            },
            "output_encoding": "signed_10_bit_twos_complement",
            "tu_admission": "back_to_back_if_it_data_in_req_is_high",
            "clock_reset": "clk_required; rst_n active_low_async",
        },
        "not_confirmed_by_answer": [
            "complete legal H/V pair subset for every lfnst_idx=0 descriptor",
            "contest-specific VTM bitDepth/SPS profile binding",
            "wide residual to signed-10 saturation-versus-low10 rule",
        ],
    }
    write("OFFICIAL_EXPERT_QA_EVIDENCE.json", qa)

    profile = {
        "schema": "step12d_engineering.vtm_profile.v1",
        "profile_name": "contest_engineering_vtm10_v1",
        "evidence_class": "documented_engineering_binding",
        "official_equivalence": "NOT_PROVEN",
        "historical_hidden_golden_equivalence": "UNKNOWN",
        "algorithm_binding": {
            "bit_depth": 10,
            "extended_precision_processing": False,
            "max_log2_transform_dynamic_range": 15,
            "derivation": "VTM SPS getMaxLog2TrDynamicRange: extended=false => 15",
        },
        "vtm_reference_build": {
            "RExt__HIGH_BIT_DEPTH_SUPPORT": 0,
            "Pel": "int16_t",
            "Intermediate_Int": "int",
        },
        "inverse_2d": {
            "vertical": {"shift": 7, "rounding_add": 64, "clip": [-32768, 32767]},
            "horizontal": {"shift": 10, "rounding_add": 512, "clip": [-32768, 32767]},
            "formula": "Clip3(min,max,(sum + 2^(shift-1)) >> shift)",
            "order": "vertical_then_horizontal",
        },
        "lfnst": {
            "shift": 7,
            "rounding_add": 64,
            "clip": [-32768, 32767],
            "main_transform_after_lfnst": "DCT2_DCT2",
        },
        "final10": {
            "default": "LOW10_TWOS_COMPLEMENT",
            "low10_formula": "bits = wide_value & 0x3ff; signed10 = bits if bits < 512 else bits - 1024",
            "alternate": {"mode": "SAT10", "range": [-512, 511], "formula": "Clip3(-512,511,wide_value)"},
            "reason": "interface specifies signed 10-bit two's-complement but no additional saturation rule",
        },
        "source_ids": ["VTM_TRQUANT_XIT", "VTM_INVERSE_MATRIX_MULT", "VTM_TYPEDEF", "OFFICIAL_EXPERT_QA_USER_PROVIDED_TRANSCRIPT"],
    }
    write("ENGINEERING_PROFILE.json", profile)

    zero_rules = {
        "schema": "step12d_engineering.vtm_zero_out_rules.v1",
        "status": "REFERENCE_RULES_BOUND_TO_ENGINEERING_PROFILE",
        "rules": {
            "lfnst_off": {
                "skip_width": "(tr_type_hor != DCT2 and width == 32) ? 16 : max(width - 32, 0)",
                "skip_height": "(tr_type_ver != DCT2 and height == 32) ? 16 : max(height - 32, 0)",
            },
            "lfnst_on": {
                "4_by_other": "skip_width=width-4; skip_height=height-4",
                "8_or_larger": "skip_width=width-8; skip_height=height-8",
            },
            "execution": "inverse primitive consumes cutoff=transform_size-skip_in_lines and explicitly zeroes skipped output lines",
        },
        "source_locators": {
            "TrQuant.cpp": {"xIT": [source_line(trquant, "int skipWidth"), source_line(trquant, "if( tu.cs->sps->getUseLFNST") ]},
            "TrQuant_EMT.cpp": {"inverseMatrixMult": [source_line(emt, "const size_t cutoff"), source_line(emt, "std::fill_n") ]},
        },
        "scope_note": "This is VTM reference behavior; any contest simplification remains an engineering-profile choice unless explicitly stated by the contest source.",
    }
    write("VTM_ZERO_OUT_RULES.json", zero_rules)

    src_trace = {
        "schema": "step12d_engineering.source_traceability.v1",
        "status": "ENGINEERING_PROFILE_BOUNDING_WITH_RESIDUAL_OFFICIAL_EQUIVALENCE_UNKNOWN",
        "sources": [
            {"id": "OFFICIAL_EXPERT_QA_USER_PROVIDED_TRANSCRIPT", "sha256": qa["sha256_normalized_answer"], "class": "official_answer_as_supplied"},
            {"id": "CANONICAL_COEFFICIENTS", "path": "03_verification/output/canonical_matrices.json", "sha256": sha256(CANONICAL), "class": "immutable_canonical_data"},
            {"id": "VTM_TRQUANT_XIT", "path": "04_reference/VTM/source/Lib/CommonLib/TrQuant.cpp", "sha256": sha256(trquant), "locators": {"xIT": [source_line(trquant, "void TrQuant::xIT"), source_line_after(trquant, "shift_1st", "void TrQuant::xIT")]}, "class": "designated_reference"},
            {"id": "VTM_INVERSE_MATRIX_MULT", "path": "04_reference/VTM/source/Lib/CommonLib/TrQuant_EMT.cpp", "sha256": sha256(emt), "locators": {"primitive": [source_line(emt, "inverseMatrixMult"), source_line(emt, "Clip3<TCoeff>")]}, "class": "designated_reference"},
            {"id": "VTM_TYPEDEF", "path": "04_reference/VTM/source/Lib/CommonLib/TypeDef.h", "sha256": sha256(typedef), "locators": {"high_bit_depth": [source_line(typedef, "RExt__HIGH_BIT_DEPTH_SUPPORT"), source_line(typedef, "typedef       int16_t         Pel")]}, "class": "designated_reference"},
            {"id": "FROZEN_R4C_64", "path": "02_rtl/rtl/p2f_dct2_64_b1_step102.sv", "sha256": sha256(ROOT / "02_rtl/rtl/p2f_dct2_64_b1_step102.sv"), "class": "immutable_historical_reference"},
            {"id": "FROZEN_STEP12B_WRAPPER", "path": "02_rtl/rtl/step12b_dct2_64_wrapper.sv", "sha256": sha256(ROOT / "02_rtl/rtl/step12b_dct2_64_wrapper.sv"), "class": "immutable_historical_reference"},
        ],
        "classification_rules": {
            "official_required": "directly stated by contest answer/attachment",
            "reference_only": "VTM semantics without a contest binding",
            "engineering_assumption": "explicit profile choice required to proceed; never described as official",
        },
    }
    write("ENGINEERING_SOURCE_TRACEABILITY.json", src_trace)

    type_names = {0: "DCT2", 1: "DST7", 2: "DCT8"}
    axis_cases = {name: {str(n): {"supported": True, "source": "official shape rows"} for n in (4, 8, 16, 32, 64) if (name == "DCT2" or n != 64)} for name in type_names.values()}
    off_tuples = []
    for w, h in dct2_shapes:
        for hor in (0, 1, 2):
            for ver in (0, 1, 2):
                if (hor != 0 and w == 64) or (ver != 0 and h == 64):
                    continue
                off_tuples.append({
                    "width": w, "height": h, "tr_type_hor": type_names[hor], "tr_type_ver": type_names[ver],
                    "lfnst_idx": 0, "tuple_status": "engineering_supported_superset", "official_legal": "unknown",
                    "derivation": "per-axis size support; not an official Cartesian-product claim",
                })
    assert len(off_tuples) == 169, len(off_tuples)
    active_shapes = sorted(set(lfnst16_shapes + lfnst48_shapes))
    active_lfnst = []
    for w, h in active_shapes:
        ntrs = 16 if (w == 4 or h == 4) else 48
        nonzero = 8 if (w, h) in {(4, 4), (8, 8)} else 16
        for set_idx in range(4):
            for idx in (1, 2):
                active_lfnst.append({
                    "width": w, "height": h, "tr_type_hor": "DCT2", "tr_type_ver": "DCT2",
                    "lfnst_tr_set_idx": set_idx, "lfnst_idx": idx, "nTrs": ntrs, "nonzero_size": nonzero,
                    "tuple_status": "official_required_as_answer_bound", "official_legal": True,
                })
    assert len(active_lfnst) == 200, len(active_lfnst)
    legal = {
        "schema": "step12d_engineering.legal_transform_matrix.v2",
        "status": "ENGINEERING_PROFILE_SUPPORT_CLOSED_OFFICIAL_HV_SUBSET_NONBLOCKING_UNKNOWN",
        "descriptor": old_legal["it_info_contract"],
        "transform_type_encoding": {"0": "DCT2", "1": "DST7", "2": "DCT8"},
        "axis_cases": axis_cases,
        "lfnst_off": {"count": len(off_tuples), "tuples": off_tuples, "official_legal_note": "Exact contest pair subset is not claimed; implementation covers this per-axis superset."},
        "lfnst_on": {"count": len(active_lfnst), "tuples": active_lfnst, "rule": "active LFNST is DCT2_DCT2; supplied set/index matrices are authoritative for this profile"},
        "shape_sources": {"DCT2": len(old_legal["official_shape_support"]["DCT2"]), "DCT8": len(old_legal["official_shape_support"]["DCT8"]), "DST7": len(old_legal["official_shape_support"]["DST7"])},
        "remaining_ambiguity": "lfnst_idx=0 exact official pair subset is unknown but nonblocking for per-axis coverage",
    }
    write("LEGAL_TRANSFORM_MATRIX.json", legal)

    lfnst_matrix = {
        "schema": "step12d_engineering.lfnst_case_matrix.v2",
        "status": "ENGINEERING_PROFILE_ACTIVE_CASES_CLOSED",
        "active_cases": active_lfnst,
        "matrix_source": "03_verification/output/canonical_matrices.json::lfnst",
        "set_idx": [0, 1, 2, 3], "lfnst_idx": [1, 2],
        "post_process": {"rounding_add": 64, "shift": 7, "clip": [-32768, 32767]},
        "main_transform": "DCT2_DCT2",
        "scatter_contract": "top-left low-frequency gather; matrix output occupies the same low-frequency scan domain before main inverse transform",
        "official_equivalence": "active LFNST pair rule source-backed; full VTM context predicates not imported into descriptor",
    }
    write("LFNST_CASE_MATRIX.json", lfnst_matrix)

    cases = []
    for name, tr_type, sizes in (("DCT2", 0, (4, 8, 16, 32, 64)), ("DST7", 1, (4, 8, 16, 32)), ("DCT8", 2, (4, 8, 16, 32))):
        for n in sizes:
            cases.append({
                "transform": name, "N": n, "group_outputs": 4, "groups": n // 4,
                "group_ii": 1, "vector_ii": n // 4, "products_per_group": 4 * n,
                "lane_mapping": "output_index=group*4+lane; coefficient row=output_index; all N inputs",
                "execution_proof_status": "scheduled_in_gate_b",
            })
    p4 = {
        "schema": "step12d_engineering.p4_execution_contract.v2",
        "status": "GATE_A_CONTRACT_READY_GATE_B_EXECUTION_PENDING",
        "cases": cases,
        "dct2_64": {"ownership": "new_profile_compliant_path_required", "frozen_r4c": "schedule/timing/reference only; arithmetic not silently reused"},
        "physical_boundary": "Gate A proves geometry only; Gate B must emit coefficient/lane/reduction execution rows",
    }
    write("P4_EXECUTION_PROOF.json", p4)

    architecture = {
        "schema": "step12d_engineering.architecture_decision.v1",
        "status": "RECOMMENDED_CANDIDATE_SELECTED_FOR_ENGINEERING_PROFILE_NOT_PHYSICAL_PROOF",
        "selection_basis": "analytic structural counts, bandwidth and mode ownership; no RTL/Vivado claim",
        "candidates": {
            "A": {"name": "fully_shared_multiplier_and_reduction", "max_direct_products_per_group": 128, "risk": ["shared reduction depth", "coefficient mux/fanout", "DCT2-64 factorization not shown"], "status": "rejected_for_first_RTL_candidate"},
            "B": {"name": "shared_multiplier_family_specific_reduction", "max_direct_products_per_group": 128, "risk": ["duplicated reductions", "mode switching", "bandwidth"], "status": "fallback_candidate"},
            "C_PRIME": {"name": "frozen_R4C_reference_plus_new_profile_unified_le32_and_dct2_64", "frozen_r4c_dsp": 128, "le32_direct_products_per_group_max": 128, "lfnst_products_per_p4_group": 64, "status": "recommended"},
        },
        "recommended_candidate": "C_PRIME",
        "dct2_64_ownership": {"frozen_r4c": "immutable historical schedule/timing/math baseline", "new_profile_path": "required for VTM10 profile postprocess; implementation in Gate B/C"},
        "lfnst_ownership": "share multiplier front-end; dedicated 16/48-term reduction/control and gather/scatter",
        "estimates_not_proof": {"dsp": "128 shared product lanes in the <=32 direct candidate; DCT2-64 implementation-dependent", "lut_ff_ram": "not estimated until RTL structure exists", "timing": "unknown until synthesis/implementation"},
    }
    write("ARCHITECTURE_DECISION.json", architecture)

    records = []
    for w, h in dct2_shapes:
        records.append({
            "width": w, "height": h, "vertical_vectors": w, "vertical_vector_length": h,
            "horizontal_vectors": h, "horizontal_vector_length": w,
            "vertical_groups_per_vector": h // 4, "horizontal_groups_per_vector": w // 4,
            "vertical_compute_cycles": w * (h // 4), "horizontal_compute_cycles": h * (w // 4),
            "single_shared_fabric_cycles": 2 * w * h // 4,
            "result_beats": w * h // 4, "single_shared_fabric_equivalent_final_points_per_cycle": 2,
            "tuple_status": "engineering_supported_superset",
        })
    cycle = {
        "schema": "step12d_engineering.cycle_resource_contract.v2",
        "status": "GATE_A_ANALYTIC_CONTRACT_READY",
        "tuple_scope": {"lfnst_off": len(off_tuples), "lfnst_on": len(active_lfnst)},
        "throughput": {"one_d": "4 complete outputs/group; group II=1; vector II=N/4", "two_d_shared_fabric": "2 final coefficients/cycle before boundary overhead", "output": "4 signed10 points per output_fire when req permits", "backpressure": "completion latency is stall-dependent; no fixed upper bound"},
        "records": records,
        "memory_mapping": {"input_raster": "row*W+col", "bank": "(row[1:0] XOR col[1:0])", "addr": "row*(W/4)+(col>>2)", "vertical_staging": "one 4-lane group per cycle; stage_full after last response", "intermediate": "owner-exclusive W*H entries", "result": "H*W/4 reserved beats in raster order"},
        "mode_switch": "all valid/owner/epoch metadata must be tagged and drained before new descriptor admission",
    }
    write("CYCLE_RESOURCE_CONTRACT.json", cycle)

    frozen_files = {
        "r4c": "02_rtl/rtl/p2f_dct2_64_b1_step102.sv",
        "wrapper": "02_rtl/rtl/step12b_dct2_64_wrapper.sv",
        "xdc": "03_verification/vivado/step12c_wrapper_2ns.xdc",
        "canonical": "03_verification/output/canonical_matrices.json",
    }
    checkpoint = {
        "schema": "step12d_engineering.gate_a_checkpoint.v1",
        "created_from_commit": git_head(),
        "base_tag": "v3.5-18",
        "base_tag_target": "7415b0acb33481af1845f63e16b93ce7c33b977b",
        "immutable_files": {k: {"path": v, "sha256": sha256(ROOT / v)} for k, v in frozen_files.items()},
        "rtl_tree_diff_at_creation": subprocess.check_output(["git", "diff", "--name-only", "HEAD", "--", "02_rtl/rtl"], cwd=ROOT, text=True).splitlines(),
        "vivado_run": False,
        "checkpoint_policy": "Gate B/C cannot pass if immutable frozen files change; new RTL must live outside frozen R4C/wrapper paths.",
    }
    assert checkpoint["rtl_tree_diff_at_creation"] == []
    write("GATE_A_CHECKPOINT.json", checkpoint)

    manifest = {
        "schema": "step12d_engineering.manifest.v1",
        "status": "GATE_A_PASS_ENGINEERING_PROFILE_RESIDUAL_OFFICIAL_EQUIVALENCE_UNKNOWN",
        "phase": "step12d_engineering_closure_gate_a_complete",
        "base_tag": "v3.5-18",
        "base_commit": checkpoint["base_tag_target"],
        "current_commit": checkpoint["created_from_commit"],
        "scope": {"frozen_r4c_unchanged": True, "frozen_wrapper_unchanged": True, "xdc_unchanged": True, "vivado_run": False, "unified_rtl_authorized": True},
        "engineering_profile": "ENGINEERING_PROFILE.json",
        "legal_matrix": "LEGAL_TRANSFORM_MATRIX.json",
        "lfnst_matrix": "LFNST_CASE_MATRIX.json",
        "architecture": "ARCHITECTURE_DECISION.json",
        "gate_a_outputs": ["OFFICIAL_EXPERT_QA_EVIDENCE.json", "ENGINEERING_PROFILE.json", "VTM_ZERO_OUT_RULES.json", "ENGINEERING_SOURCE_TRACEABILITY.json", "LEGAL_TRANSFORM_MATRIX.json", "LFNST_CASE_MATRIX.json", "P4_EXECUTION_PROOF.json", "ARCHITECTURE_DECISION.json", "CYCLE_RESOURCE_CONTRACT.json", "GATE_A_CHECKPOINT.json"],
        "residual_risk": ["exact lfnst_idx=0 official pair subset not stated; implementation uses explicitly labeled per-axis superset", "engineering VTM profile and LOW10 adapter are not proven equivalent to hidden historical golden"],
        "next_gate": "Gate B unified P4 1-D RTL and independent Oracle regression",
    }
    write("STEP12D_ENGINEERING_MANIFEST.json", manifest)
    if EMIT:
        print(json.dumps(ARTIFACT_TEXT, ensure_ascii=False))
    else:
        print(json.dumps({"status": manifest["status"], "off_tuple_count": len(off_tuples), "active_lfnst_count": len(active_lfnst), "candidate": architecture["recommended_candidate"], "immutable_rtl_diff": checkpoint["rtl_tree_diff_at_creation"]}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
