# V3.5-17.2 Step12B cycle model

Status: PASS

A single IntegrationModel.tick() advances input, synchronous memories,
the persistent R4C contract, V/H scheduling, live result writes and output hold/skid.

| case | cycles | vectors | vector II | result writes | result fires |
|---|---:|---:|---|---:|---:|
| zero | 2130 | 128 | {'vertical': [16], 'horizontal': [16]} | 1024 | 1024 |
| sparse | 2135 | 128 | {'vertical': [16], 'horizontal': [16]} | 1024 | 1024 |
| alternating | 6226 | 128 | {'vertical': [16], 'horizontal': [16]} | 1024 | 1024 |
| random | 6225 | 128 | {'vertical': [16], 'horizontal': [16]} | 1024 | 1024 |

two-TU: {'cycles': 7090, 'result_writes': 2048, 'result_fires': 2048, 'stats': {'input_cache_full': 0, 'staging_wait': 0, 'result_capacity_wait': 858, 'output_backpressure': 5000, 'epoch_scrub': 0}}
vector_id_wrap: {'groups': 2048, 'first_ids': [65534, 65535, 0, 1]}
epoch_wrap: {'tus': 10, 'scrub_events': 8192, 'scrub_episodes': {'inputA:1': 4096, 'inputB:1': 4096}, 'other_cache_progress_during_scrub': True, 'scrub_mutation_gate': {'wrong_scrub_index_rejected': True, 'missing_scrub_transaction_rejected': True, 'missing_scrub_bank_rejected': True, 'wrong_scrub_cache_rejected': True, 'scrub_access_rejected': True}, 'cycles': 27897}
mutation_gate (26 checker mutations): {'trace_rollback_rejected': True, 'missing_result_write_rejected': True, 'horizontal_stage16_mutation_rejected': True, 'result_value_mutation_rejected': True, 'early_vector_start_rejected': True, 'duplicate_kernel_group_rejected': True, 'wrong_vector_group_rejected': True, 'intermediate_overwrite_rejected': True, 'write_without_reservation_rejected': True, 'same_address_rdw_rejected': True, 'early_ram_response_rejected': True, 'late_ram_response_rejected': True, 'output_hold_mutation_rejected': True, 'output_drop_rejected': True, 'output_duplicate_rejected': True, 'wrong_done_timing_rejected': True, 'descriptor_misbind_rejected': True, 'bank_conflict_rejected': True, 'scrub_access_rejected': True, 'wrong_stage_tu_owner_rejected': True, 'wrong_stage_lane_rejected': True, 'wrong_stage_slot_rejected': True, 'wrong_stage_bank_rejected': True, 'swapped_memory_request_id_rejected': True, 'missing_memory_response_rejected': True, 'duplicate_memory_response_rejected': True}
Staging reads use same-edge request/capture (delta=0); ResultMemory uses request C → response C+1.
This is the executable Python contract gate. Public RTL trace reconciliation remains a separate fail-closed audit; no free event offsets are permitted.

Model-side functional/protocol gate is PASS for the scoped 64x64 DCT2xDCT2 wrapper; no Vivado or full-core timing claim is made.
