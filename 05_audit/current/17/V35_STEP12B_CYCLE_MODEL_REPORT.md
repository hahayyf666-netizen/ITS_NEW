# V3.5-17 Step12B cycle model

Status: PASS

A single IntegrationModel.tick() advances input, synchronous memories,
the persistent R4C contract, V/H scheduling, live result writes and output hold/skid.

| case | cycles | vectors | vector II | result writes | result fires |
|---|---:|---:|---|---:|---:|
| zero | 2130 | 128 | {'vertical': [16], 'horizontal': [16]} | 1024 | 1024 |
| sparse | 2135 | 128 | {'vertical': [16], 'horizontal': [16]} | 1024 | 1024 |
| alternating | 6226 | 128 | {'vertical': [16], 'horizontal': [16]} | 1024 | 1024 |
| random | 6225 | 128 | {'vertical': [16], 'horizontal': [16]} | 1024 | 1024 |

The model is a Step12B functional/protocol pre-gate; no Vivado or full-core timing claim is made.
