# R3R negative structural tests

- `wrong_fixed_source`: PASS (rejected: ValueError: source pair mismatch: {'(0, 0)': {'expected': [(0, 1)], 'actual': [(0, 2)]}})
- `third_pair`: PASS (rejected: ValueError: source pair mismatch: {'(0, 0)': {'expected': [(0, 1)], 'actual': [(0, 1), (0, 2)]}})
- `wrong_legal_pair`: PASS (rejected: ValueError: source pair mismatch: {'(0, 0)': {'expected': [(0, 1)], 'actual': [(2, 3)]}})
- `stale_terminal_sampling`: PASS (rejected: ValueError: actual terminal coverage is not exactly 0..63)
- `duplicate_terminal_dot`: PASS (rejected: ValueError: duplicate actual terminal dot 0)
