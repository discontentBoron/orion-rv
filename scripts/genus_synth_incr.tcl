######################################################################
#         Genus synthesis script — incremental
#   Usage (one call per stage, or STAGE=all for running all stages):
#   genus -f genus.tcl -execute "set PROJECT_ROOT ..; \
#           set DESIGN_NAME orion_top; \
#           set STAGE elab"
#
######################################################################
puts "INFO: Beginning Genus Synthesis Flow"

foreach v {PROJECT_ROOT DESIGN_NAME} {
    if {![info exists $v]} { error "$v is not set." }
}
if {![info exists STAGE]} { set STAGE "all" }

set RTL_DIR  $PROJECT_ROOT/src/rtl
set SYN_DIR  $PROJECT_ROOT/syn/$DESIGN_NAME
set CKPT_DIR $SYN_DIR/checkpoints
set POST_SYN_DIR $PROJECT_ROOT/post_syn/$DESIGN_NAME
file mkdir $SYN_DIR
file mkdir $CKPT_DIR
file mkdir $POST_SYN_DIR
set SDC_FILE $PROJECT_ROOT/inputs/${DESIGN_NAME}.sdc

set ckpt(elab)    $CKPT_DIR/${DESIGN_NAME}_elab.db
set ckpt(generic) $CKPT_DIR/${DESIGN_NAME}_generic.db
set ckpt(map)     $CKPT_DIR/${DESIGN_NAME}_map.db

source $PROJECT_ROOT/libraries/libraries.freepdk45.tcl
set_db lib_search_path $genus_lib_search_path
set_db lef_library $lef_files
read_libs $genus_lib_files

###############################################################################
# Stage: elaborate — always runs fresh, it's the cheap step
###############################################################################
if {[file exists $ckpt(elab)] && $STAGE ni {elab all}} {
    puts "INFO: Restoring elaborate checkpoint: $ckpt(elab)"
    read_db $ckpt(elab)
} else {
    puts "INFO: Reading RTL..."
    read_hdl -sv $RTL_DIR/orion_pkg.sv
    foreach f {fetch_unit decode_unit rename_unit reorder_buffer issue_queue \
               register_read regread_demux alu mul div branch lsu store_buffer \
               icache dcache} {
        read_hdl -sv $RTL_DIR/${f}.sv
    }
    read_hdl -sv -define USE_OPENRAM=1 -define SYNTH_MACRO=1 $RTL_DIR/sram_1rw.sv
    read_hdl -sv $RTL_DIR/${DESIGN_NAME}.sv

    elaborate $DESIGN_NAME
    check_design -unresolved

    if {![file exists $SDC_FILE]} { error "SDC file not found at $SDC_FILE" }
    read_sdc $SDC_FILE

    write_db $ckpt(elab)
    puts "INFO: Checkpoint written: $ckpt(elab)"
}
if {$STAGE eq "elab"} { puts "INFO: Stopping after elaborate."; exit 0 }

set_db syn_generic_effort medium
set_db syn_map_effort     high
set_db syn_opt_effort     high
set_db auto_ungroup       none

###############################################################################
# Stage: syn_generic
###############################################################################
if {[file exists $ckpt(generic)] && $STAGE ni {generic all}} {
    puts "INFO: Restoring syn_generic checkpoint: $ckpt(generic)"
    read_db $ckpt(generic)
} else {
    puts "INFO: Starting syn_generic..."
    syn_generic
    write_db $ckpt(generic)
    report_timing > $SYN_DIR/generic_timing.rpt
    report_area   > $SYN_DIR/generic_area.rpt
    puts "INFO: Checkpoint written: $ckpt(generic)"
}
if {$STAGE eq "generic"} { puts "INFO: Stopping after syn_generic."; exit 0 }

###############################################################################
# Stage: syn_map
###############################################################################
if {[file exists $ckpt(map)] && $STAGE ni {map all}} {
    puts "INFO: Restoring syn_map checkpoint: $ckpt(map)"
    read_db $ckpt(map)
} else {
    puts "INFO: Starting syn_map..."
    syn_map
    write_db $ckpt(map)
    report_timing > $SYN_DIR/map_timing.rpt
    report_area   > $SYN_DIR/map_area.rpt
    puts "INFO: Checkpoint written: $ckpt(map)"
}
if {$STAGE eq "map"} { puts "INFO: Stopping after syn_map."; exit 0 }

###############################################################################
# Stage: syn_opt — final stage, writes deliverables
###############################################################################
puts "INFO: Starting syn_opt..."
syn_opt
write_db [file join $CKPT_DIR ${DESIGN_NAME}_opt.db]

puts "INFO: Writing final reports and outputs..."
report_timing                   > $SYN_DIR/timing.rpt
report_area                     > $SYN_DIR/area.rpt
report_power                    > $SYN_DIR/power.rpt
report_qor                      > $SYN_DIR/qor.rpt
check_design -all               > $SYN_DIR/check_design.rpt

write_hdl > [file join $SYN_DIR ${DESIGN_NAME}_netlist.v]
write_sdc > [file join $SYN_DIR ${DESIGN_NAME}_syn.sdc]
write_db    [file join $SYN_DIR ${DESIGN_NAME}.db]
puts "INFO: Generating Innovus Handoff Scripts..."
write_design -innovus -base_name orion_core $POST_SYN_DIR/orion_core
puts "INFO: Synthesis complete."
