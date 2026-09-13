# Boundary-PRE: physical registered-neighbor context for the frozen wrapper.
# The DUT is not modified.  The top-level ports drive source registers and
# sink registers capture all DUT outputs.  The existing zero-delay input/output
# assumptions remain on the external harness boundary; the paths from source
# Q to DUT input registers and DUT outputs to sink D are internal physical
# paths and are reported separately.

create_clock -name clk -period 2.000 [get_ports clk]

# The only top-level port is the clock. Data source/sink registers are internal
# registered neighbors; reset is held inactive for this data-path PRE and is
# not a timing endpoint in this experiment.

# No false paths, multicycle paths, or timing exceptions are used.  The
# implementation supplies the actual clock tree and physical adjacency.
