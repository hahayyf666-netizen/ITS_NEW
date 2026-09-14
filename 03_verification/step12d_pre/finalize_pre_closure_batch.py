"""Finalize the Step12D-PRE batch without authorizing RTL.

The contest attachment supplies shape rows and interface fields, while the
vendored VTM supplies context-dependent reference semantics.  This script
keeps those evidence classes separate and records a deterministic PASS/STOP
decision.  It intentionally cannot promote a VTM tuple to official legality.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"
VTM = ROOT / "04_reference" / "VTM" / "source" / "Lib"


def read_json(name: str) -> dict:
    return json.loads((EVIDENCE / name).read_text(encoding="utf-8"))


def write_json(name: str, value: dict) -> None:
    (EVIDENCE / name).write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    digest.update(path.read_bytes())
    return digest.hexdigest().upper()


def line(path: Path, needle: str) -> int:
    for number, text in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if needle in text:
            return number
    raise AssertionError(f"missing source marker {needle!r} in {path}")


def main() -> int:
    resolution = EVIDENCE / "SOURCE_CONTRACT_RESOLUTION.json"
    if resolution.exists():
        state = json.loads(resolution.read_text(encoding="utf-8"))
        print(json.dumps({
            "status": "NO_REWRITE_SOURCE_RESOLUTION_SUPERSEDES_FINAL_BATCH",
            "source_resolution_status": state["status"],
            "validator": "validate_source_contract_resolution.py",
        }, ensure_ascii=False, indent=2))
        return 0

    legal = read_json("LEGAL_TRANSFORM_MATRIX.json")
    source = read_json("SOURCE_TRACEABILITY.json")
    lfnst = read_json("LFNST_CASE_MATRIX.json")
    architecture = read_json("ARCHITECTURE_COMPARISON.json")
    manifest = read_json("STEP12D_PRE_MANIFEST.json")

    trquant = VTM / "CommonLib" / "TrQuant.cpp"
    writer = VTM / "EncoderLib" / "CABACWriter.cpp"
    reader = VTM / "DecoderLib" / "CABACReader.cpp"
    typedef = VTM / "CommonLib" / "TypeDef.h"
    unit_tools = VTM / "CommonLib" / "UnitTools.cpp"
    assert trquant.exists() and writer.exists() and reader.exists() and typedef.exists()

    vtm_context = {
        "schema": "step12d_pre.vtm_context_closure.v1",
        "status": "REFERENCE_CONTEXT_COMPLETE_OFFICIAL_CONTEST_MAPPING_UNRESOLVED",
        "official_legal": False,
        "source_files": [
            {
                "source_id": "VTM_TRQUANT_GETTRTYPES",
                "path": "04_reference/VTM/source/Lib/CommonLib/TrQuant.cpp",
                "sha256": sha256(trquant),
                "locators": {
                    "getTrTypes": [line(trquant, "void TrQuant::getTrTypes"), line(trquant, "if (isExplicitMTS)")],
                    "implicit_predicates": [line(trquant, "const bool isImplicitMTS"), line(trquant, "bool widthDstOk")],
                    "lfnst_inverse": [line(trquant, "void TrQuant::invLfnstNxN"), line(trquant, "void TrQuant::xInvLfnst")],
                },
            },
            {
                "source_id": "VTM_CABAC_MTS_LFNST_GATES",
                "path": "04_reference/VTM/source/Lib/EncoderLib/CABACWriter.cpp",
                "sha256": sha256(writer),
                "locators": {
                    "mts_gate": [line(writer, "void CABACWriter::mts_idx"), line(writer, "&& cu.lfnstIdx == 0")],
                    "lfnst_index": [line(writer, "const uint32_t idxLFNST"), line(writer, "assert( idxLFNST < 3 )")],
                },
            },
            {
                "source_id": "VTM_CABAC_READER_MTS_LFNST_GATES",
                "path": "04_reference/VTM/source/Lib/DecoderLib/CABACReader.cpp",
                "sha256": sha256(reader),
                "locators": {
                    "mts_gate": [line(reader, "void CABACReader::mts_idx"), line(reader, "&& cu.lfnstIdx == 0")],
                    "lfnst_index": [line(reader, "void CABACReader::residual_lfnst_mode"), line(reader, "cu.lfnstIdx = idxLFNST")],
                },
            },
            {
                "source_id": "VTM_MTS_ENUM",
                "path": "04_reference/VTM/source/Lib/CommonLib/TypeDef.h",
                "sha256": sha256(typedef),
                "locators": {"mts_type": [line(typedef, "enum class MtsType"), line(typedef, "DCT8_DCT8")]},
            },
            {
                "source_id": "VTM_LFNST_ISP_MIP_GATES",
                "path": "04_reference/VTM/source/Lib/CommonLib/UnitTools.cpp",
                "sha256": sha256(unit_tools),
                "locators": {
                    "isp_gate": [line(unit_tools, "bool CU::canUseLfnstWithISP")],
                    "mip_gate": [line(unit_tools, "bool allowLfnstWithMip")],
                },
            },
        ],
        "reference_rules": [
            "getTrTypes defaults to DCT2_DCT2 when MTS is disabled or not selected.",
            "implicit MTS/ISP changes horizontal and/or vertical type to DST7 only when the corresponding dimension is 4..16.",
            "explicit MTS enumerates DST7_DST7, DCT8_DST7, DST7_DCT8, and DCT8_DCT8, and is gated by lfnstIdx == 0.",
            "SBT has additional context-dependent mixed-pair branches and DCT2 fallback branches.",
            "LFNST uses 4x4 or 8x8 low-frequency gathering, nTrs 16 or 48, lfnst index 1..2, scan-dependent scatter, and Clip3 post-processing.",
        ],
        "contest_mapping_gaps": [
            "The attachment lists axis shape rows but does not state the complete horizontal/vertical pair coupling.",
            "The attachment does not map lfnst_tr_set_idx to VTM intra-mode/lut selection or state the complete main-transform coupling when LFNST is enabled.",
            "VTM context predicates (intra/inter, ISP, SBT, MIP, component and scan constraints) are not fields of the frozen 22-bit contest descriptor.",
        ],
    }
    write_json("VTM_CONTEXT_CLOSURE.json", vtm_context)

    source["status"] = "FINAL_CLOSURE_BATCH_STOP_UNRESOLVED_SOURCE_CONTRACT"
    source["source_findings"][2]["finding"] = (
        "The VTM pair rules can be mechanically expanded against the official shape-row intersections into "
        "95 LFNST-off reference candidates, including six implicit-MTS mixed-pair candidates."
    )
    source["source_findings"][2]["status"] = "reference_candidate_derivation_recorded_not_official"
    source["final_closure"] = {
        "reference_context_evidence": "VTM_CONTEXT_CLOSURE.json",
        "official_tuple_mapping": "unresolved",
        "official_legal_promotion": False,
        "stop_reason": "official descriptor H/V and LFNST coupling are not stated by the attachment",
    }
    write_json("SOURCE_TRACEABILITY.json", source)

    legal["status"] = "OFFICIAL_SHAPE_ROWS_COMPLETE_REFERENCE_CONTEXT_COMPLETE_OFFICIAL_TUPLE_MAPPING_UNRESOLVED"
    legal["complete_descriptor_tuples"]["status"] = "REFERENCE_CANDIDATES_AVAILABLE_OFFICIAL_HV_LFNST_MAPPING_UNRESOLVED"
    legal["complete_descriptor_tuples"]["reference_candidate_tuple_count_lfnst_off"] = 95
    legal["complete_descriptor_tuples"]["reference_context_evidence"] = "VTM_CONTEXT_CLOSURE.json"
    legal["complete_descriptor_tuples"]["official_legal_rule"] = (
        "Only attachment-backed complete tuples may be official_required; VTM-derived tuples remain reference_only."
    )
    write_json("LEGAL_TRANSFORM_MATRIX.json", legal)

    lfnst["status"] = "REFERENCE_CONTEXT_COMPLETE_OFFICIAL_CONTEST_MAPPING_UNRESOLVED"
    lfnst["reference_context_evidence"] = "VTM_CONTEXT_CLOSURE.json"
    lfnst["contest_mapping_gap"] = {
        "status": "P1_STOP",
        "official_fields": ["lfnst_tr_set_idx", "lfnst_idx"],
        "unresolved": [
            "set-index to matrix/lut identity mapping in the contest interface",
            "complete H/V main-transform coupling while lfnst_idx is nonzero",
            "whether the VTM intra/ISP/MIP/component predicates are part of the contest legal environment",
        ],
    }
    lfnst["source_backed_closure"] = False
    write_json("LFNST_CASE_MATRIX.json", lfnst)

    architecture["status"] = "STOP_SOURCE_MATRIX_UNRESOLVED_ANALYTIC_COMPARISON_ONLY"
    architecture["comparison_scope"] = {
        "tuple_scope": "95 VTM reference candidates only; official tuple set unresolved",
        "evidence_class": "pre_synthesis_structural_and_analytic_estimate",
        "physical_proof": False,
        "vivado_run": False,
    }
    architecture["candidates"] = {
        "A": {
            "name": "fully_shared_multiplier_and_reduction",
            "coverage": "reference DCT2/DST7/DCT8 <=32; DCT2-64 factorized schedule not proven",
            "exact_structural_counts": {
                "direct_products_per_group_max": 128,
                "max_reduction_nodes_for_four_N32_outputs": 124,
                "group_ii_target": 1,
            },
            "pre_synthesis_estimates": {
                "multiplier_instances": "128 if no same-cycle reuse",
                "lut_ff_ram_dsp": "unknown until RTL/synthesis",
                "coefficient_bandwidth": "up to 128 coefficients per direct N=32 group cycle",
                "pipeline_stages": "architecture-dependent",
            },
            "risks": ["configurable coefficient mux/fanout", "shared reduction timing", "mode-switch isolation"],
            "status": "not_selectable_before_source_closure",
        },
        "B": {
            "name": "shared_multiplier_family_specific_reduction",
            "coverage": "reference DCT2/DST7/DCT8 <=32; DCT2-64 factorized schedule not proven",
            "exact_structural_counts": {
                "direct_products_per_group_max": 128,
                "max_reduction_nodes_for_four_N32_outputs": 124,
                "group_ii_target": 1,
            },
            "pre_synthesis_estimates": {
                "multiplier_instances": "128 if no same-cycle reuse",
                "lut_ff_ram_dsp": "unknown until RTL/synthesis",
                "coefficient_bandwidth": "up to 128 coefficients per direct N=32 group cycle",
                "pipeline_stages": "family-specific and architecture-dependent",
            },
            "risks": ["duplicated reduction networks", "mode boundary state", "coefficient routing"],
            "status": "not_selectable_before_source_closure",
        },
        "C": {
            "name": "frozen_R4C_64_plus_new_le32_lfnst_kernel",
            "coverage": "frozen DCT2-64 reference plus new <=32/LFNST kernel if legal scope confirms it",
            "exact_structural_counts": {
                "frozen_r4c_dsp": 128,
                "direct_le32_product_requirement_max": 128,
                "lfnst_p4_product_requirement": 64,
            },
            "pre_synthesis_estimates": {
                "parallel_multiplier_instances": 256,
                "time_shared_multiplier_instances": "128 only with proven non-overlap schedule",
                "lut_ff_ram": "unknown until RTL/synthesis",
                "pipeline_stages": "new kernel architecture-dependent",
            },
            "risks": ["resource duplication", "cross-kernel mode/ownership scheduling", "new kernel timing"],
            "status": "conditional_candidate_not_finally_selected",
        },
    }
    architecture["recommended_candidate"] = "NONE_SOURCE_CONTRACT_BLOCKED"
    architecture["conditional_preference"] = (
        "C is a provisional implementation preference only if official scope permits retaining frozen R4C-64; it is not a PRE selection."
    )
    architecture["selection_blockers"] = [
        "official H/V tuple coupling is unresolved",
        "official LFNST coupling and set/index mapping are unresolved",
        "physical multiplier/reduction implementation is not proven without RTL/synthesis",
    ]
    architecture["not_a_timing_proof"] = True
    write_json("ARCHITECTURE_COMPARISON.json", architecture)

    decision = {
        "schema": "step12d_pre.final_closure_decision.v1",
        "status": "STOP",
        "decision": "STOP_UNRESOLVED_SOURCE_CONTRACT",
        "base_tag": "v3.5-18",
        "base_commit": "7415b0acb33481af1845f63e16b93ce7c33b977b",
        "scope_preserved": {
            "rtl_tree_changed": False,
            "vivado_run": False,
            "unified_rtl_authorized": False,
            "frozen_r4c_or_wrapper_or_xdc_modified": False,
        },
        "completed_evidence": [
            "official shape/interface extraction recorded",
            "VTM transform-pair and LFNST reference context extracted with hashes and locators",
            "95 reference tuple derivation and provenance validated",
            "13-case independent arithmetic P4 execution validated",
            "65-vector fixed-point reference cross-check validated",
            "57-row logical memory mapping and 95-candidate tagged 2-D reference dataflow validated",
            "A/B/C analytic structural comparison recorded without physical claims",
        ],
        "blockers": [
            {
                "id": "SRC-DESC-COUPLING-01",
                "severity": "P1",
                "description": "Official attachment does not define complete horizontal/vertical transform-type coupling for the 22-bit descriptor.",
            },
            {
                "id": "SRC-LFNST-COUPLING-01",
                "severity": "P1",
                "description": "Official attachment does not map LFNST set/index to complete main-transform coupling and VTM context predicates.",
            },
            {
                "id": "FIXED-POINT-SOURCE-01",
                "severity": "P1",
                "description": "Per-case source-backed fixed-point promotion is not complete; existing checks remain reference/baseline evidence.",
            },
            {
                "id": "ARCH-SELECT-01",
                "severity": "P1",
                "description": "A/B/C and LFNST ownership cannot be finally selected before the official case universe and source-backed contracts close; physical feasibility is also not proven in PRE.",
            },
        ],
        "official_vs_reference_rule": "VTM-derived tuples remain reference_only; engineering assumptions cannot close an unresolved official requirement.",
        "next_action": "Obtain authoritative H/V and LFNST coupling clarification, then rerun the final matrix-dependent evidence batch.",
    }
    write_json("FINAL_CLOSURE_DECISION.json", decision)

    manifest["status"] = "STOP"
    manifest["phase"] = "final_closure_batch_complete_stop_unresolved_source_contract"
    manifest["source_issue_count"] = 3
    manifest["resolved_source_issue_count"] = 1
    manifest["complete_descriptor_tuple_matrix"] = "REFERENCE_95_ONLY_OFFICIAL_HV_LFNST_MAPPING_UNRESOLVED"
    manifest["architecture_candidate"] = "NOT_SELECTED_SOURCE_CONTRACT_BLOCKED"
    manifest["lfnst_ownership"] = "NOT_SELECTED_SOURCE_CONTRACT_BLOCKED"
    manifest["pre_gate"] = "STOP_UNRESOLVED_SOURCE_CONTRACT"
    manifest["final_closure_decision"] = "FINAL_CLOSURE_DECISION.json"
    manifest["completed_evidence"] = list(dict.fromkeys(manifest["completed_evidence"] + [
        "VTM_CONTEXT_CLOSURE.json: complete reference branch and LFNST context with source hashes",
        "final 95-candidate matrix reclassified as reference_only pending official mapping",
        "analytic A/B/C comparison recorded with exact structural counts separated from estimates",
        "FINAL_CLOSURE_DECISION.json: final batch STOP with finite P1 blockers",
    ]))
    manifest["blockers"] = decision["blockers"]
    manifest["next_actions"] = [
        "obtain authoritative official H/V transform-type coupling for the 22-bit descriptor",
        "obtain authoritative official LFNST set/index and main-transform coupling rules",
        "after source closure, promote per-case fixed-point contracts and rerun all matrix-dependent evidence",
        "after the final case universe closes, select one A/B/C candidate and LFNST ownership; no unified RTL before then",
    ]
    write_json("STEP12D_PRE_MANIFEST.json", manifest)

    print(json.dumps({
        "status": decision["status"],
        "decision": decision["decision"],
        "blocker_count": len(decision["blockers"]),
        "reference_tuple_count": 95,
        "official_legal": False,
        "unified_rtl_authorized": False,
        "vivado_run": False,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
