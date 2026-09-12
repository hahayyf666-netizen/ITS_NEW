# V3.5-17 Step12B cycle model

Status: PASS

A single IntegrationModel.tick() advances input, synchronous memories,
the persistent R4C contract, V/H scheduling, live result writes and output hold/skid.

| case | cycles | vectors | vector II | result writes | result fires |
|---|---:|---:|---|---:|---:|
| zero | 2132 | 128 | {'vertical': [16], 'horizontal': [16]} | 1024 | 1024 |
| sparse | 2137 | 128 | {'vertical': [16], 'horizontal': [16]} | 1024 | 1024 |
| alternating | 6228 | 128 | {'vertical': [16], 'horizontal': [16]} | 1024 | 1024 |
| random | 6227 | 128 | {'vertical': [16], 'horizontal': [16]} | 1024 | 1024 |

two-TU: {'cycles': 7094, 'result_writes': 2048, 'result_fires': 2048, 'stats': {'input_cache_full': 0, 'staging_wait': 0, 'result_capacity_wait': 860, 'output_backpressure': 5000, 'epoch_scrub': 0}}
vector_id_wrap: {'groups': 2048, 'first_ids': [65534, 65535, 0, 1]}
epoch_wrap: {'tus': 10, 'scrub_events': 2048, 'cycles': 21284}
mutation_gate: {'trace_rollback_rejected': True, 'missing_result_write_rejected': True, 'horizontal_stage16_mutation_rejected': True, 'result_value_mutation_rejected': True}

The model is a Step12B functional/protocol pre-gate; no Vivado or full-core timing claim is made.
