#########################################################
#               Genus synthesis script                  #                   
#   Usage:                                              #
#       Navigate to the workspace dir. and run          #
#       genus -f ../scripts/gens.tcl \                  #
#               -set PROJECT_ROOT=.. \                  #
#               -set DESIGN_NAME=<top module name>      #
#########################################################      
puts "INFO: Beginning Genus Synthesis Flow"
# Check if $PROJECT_ROOT is set
if {![info exists PROJECT_ROOT]} {
    error "PROJECT_ROOT is not set. Please set it before sourcing this script."
}
# Check if design name is set
if {![info exists DESIGN_NAME]} {
    error "DESIGN_NAME is not set."
}
# Set project path
set RTL_DIR $PROJECT_ROOT/src/rtl
set SYN_DIR $PROJECT_ROOT/syn/$DESIGN_NAME
file mkdir $SYN_DIR
set SDC_FILE    $PROJECT_ROOT/inputs/${DESIGN_NAME}.sdc

# Load PDK libraries
source $PROJECT_ROOT/libraries/libraries.freepdk45.tcl

set_db lib_search_path $genus_lib_search_path
read_libs $genus_lib_files

#Read design files
read_hdl -sv $RTL_DIR/orion_pkg.sv
read_hdl -sv $RTL_DIR/${DESIGN_NAME}.sv

elaborate $DESIGN_NAME
check_design -unresolved

# Read SDC file
if {![file exists $SDC_FILE]} {
    puts "ERROR: SDC file not found at $SDC_FILE"
    exit 1
}

read_sdc $SDC_FILE

# Begin Synthesis
set_db syn_generic_effort  medium
set_db syn_map_effort      medium
set_db syn_opt_effort      high

# Preserve hierarchy 
set_db auto_ungroup        none

puts "INFO: Starting syn_generic..."
syn_generic

puts "INFO: Starting syn_map..."
syn_map

puts "INFO: Starting syn_opt..."
syn_opt


# Report generation
puts "INFO: Writing reports..."

report_timing -num_paths 10   > $SYN_DIR/timing.rpt
report_area                   > $SYN_DIR/area.rpt
report_power -effort low      > $SYN_DIR/power.rpt
report_qor                    > $SYN_DIR/qor.rpt
check_design -all             > $SYN_DIR/check_design.rpt

# Design output
puts "INFO: Writing outputs..."
set generic_filename    [file join $SYN_DIR ${DESIGN_NAME}_generic.v]
set netlist_filename    [file join $SYN_DIR ${DESIGN_NAME}_netlist.v]
set sdc_filename        [file join $SYN_DIR ${DESIGN_NAME}_syn.sdc]
set db_file             [file join $SYN_DIR ${DESIGN_NAME}.db]
write_hdl  -generic         > $generic_filename
write_hdl                   > $netlist_filename
write_sdc                   > $sdc_filename
write_db                    $db_file    

puts "INFO: Synthesis complete."
puts "INFO: Netlist  : $SYN_DIR/generic_filename"
puts "INFO: SDC      : $SYN_DIR/netlist_filename"
puts "INFO: Timing   : $SYN_DIR/genr.rpt"
puts "INFO: Area     : $SYN_DIR/genr.rpt"