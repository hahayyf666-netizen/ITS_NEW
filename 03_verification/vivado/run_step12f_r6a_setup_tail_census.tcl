# Step12F P9-R6A read-only setup-tail classification.
#
# This entry point deliberately reuses the audited R5F endpoint/family
# classifier.  It opens one already-routed R6 DCP and performs timing/netlist
# queries only.  No synthesis, optimization, placement, phys_opt, routing,
# constraint loading, checkpoint writing, or design-object mutation is
# permitted here.

set dcp_path $::env(STEP12F_R6A_POSTROUTE_DCP)
set out_dir  $::env(STEP12F_R6A_CENSUS_DIR)
file mkdir $out_dir

# The R5F classifier is the frozen classification implementation.  Its
# environment names are set locally for the delegated read-only query.
set ::env(STEP12F_R5F_POSTROUTE_DCP) $dcp_path
set ::env(STEP12F_R5F_CENSUS_DIR) $out_dir
set ::env(STEP12F_SKIP_PATH_SIGNATURE) 1
set classifier [file join [file dirname [info script]] run_step12f_r5f_setup_census.tcl]
puts "P9R6A_CLASSIFIER=$classifier"
puts "P9R6A_DELEGATION=R5F_READ_ONLY_CLASSIFIER"
source $classifier
puts "P9R6A_CENSUS_DONE"
