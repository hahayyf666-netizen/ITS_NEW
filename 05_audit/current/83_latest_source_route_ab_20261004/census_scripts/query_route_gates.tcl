puts "P9_ROUTE_GATES_START"
puts "VIVADO_VERSION=[version -short]"
puts "MAX_THREADS=[get_param general.maxThreads]"
source $::env(STEP12F_STRUCTURE_SCRIPT)
source $::env(STEP12F_POSITIVE_SCRIPT)
puts "P9_ROUTE_GATES_DONE"
