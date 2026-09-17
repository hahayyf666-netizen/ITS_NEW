# Step12F-P9-R5G-G0.6R1 — Corrected Balanced Producer Locality Frontier

Status: `CLOSED_READ_ONLY`; decision: **R1_INVALID_OR_INCOMPLETE**

- Fixed DCP SHA-256: `D18A6213468C4EE270D03AF924BE53BE7298DD71A70C5B2651ED0DDB8767552C` (match=True)
- Inventory source: `G05_LEGACY_SITE_INVENTORY_NOT_REEXTRACTED`
- Inventory bbox: `{'x_min': 40, 'x_max': 112, 'y_min': 55, 'y_max': 135}`; required bbox: `{'x_min': 40, 'x_max': 112, 'y_min': 55, 'y_max': 180}`
- Inventory complete: `False`; producer bbox covered: `False`
- Vivado executable available for fresh extraction: `False`
- NO_MOVE_REFERENCE regression: `True`
- bit 62 (+12 tiles) regression: `True` (observed `12.0`)

No frontier was generated because the supplied inventory is the legacy G0.5 range and does not cover the frozen R1 envelope. Run the read-only Vivado extraction Tcl, then rerun this script with the fresh inventory.
