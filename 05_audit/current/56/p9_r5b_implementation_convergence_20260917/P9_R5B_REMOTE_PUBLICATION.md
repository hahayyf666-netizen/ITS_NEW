# P9-R5B remote publication

Remote compact evidence mirror published to `main` in commit `54977a67ca67c033e8efd686df1625464b7ea68e` (parent `64219104be0e3afd313c180f7d3b85f36e8694de`). The local full-evidence commit is `10f2bfa` and contains the complete Vivado reports, logs, and four binary DCPs; GitHub mirror publication intentionally includes only text/JSON/Markdown evidence and command transcripts because the DCPs are binary artifacts.

R5B result: no setup+hold signoff candidate. Best observed B0 NetDelay replay is setup WNS `-0.063 ns`, TNS `-1.776 ns`, 84 failing endpoints; hold WHS `-0.080 ns`, THS `-4.764 ns`, 65 failing endpoints. B1 is unchanged; B2 slightly improves hold TNS but degrades setup; B4 makes no further change. R5 is retained, R6 RTL and new tag remain unauthorized.

All four targeted H-read qualification runs report pending/run/stage to H-response = 0 paths and registered-address to H-response = 20 paths. Full binary evidence remains at the local path documented by `P9_R5B_MANIFEST.json`.
