##############################################################################
# libraries_freepdk45.tcl
# FreePDK45 + NanGate OpenCell (mflowgen ADK) + OpenRAM macros
# Usage: set PROJECT_ROOT (or PDK_ROOT), then source this file
##############################################################################

# --------------------------------------------------------------------------
# 1.  Roots
# --------------------------------------------------------------------------
if {![info exists PROJECT_ROOT]} { error "PROJECT_ROOT is not set." }
if {![info exists PDK_ROOT]}     { set PDK_ROOT $PROJECT_ROOT/pdk/freepdk-45nm }

# --------------------------------------------------------------------------
# 2.  Macros (OpenRAM SRAMs)
# --------------------------------------------------------------------------
set sram_names [list \
    dcache_data_sram_1rw0r0w_32_512_freepdk45 \
    dcache_tag_sram_1rw0r0w_21_64_freepdk45 \
    icache_data_sram_1rw0r0w_32_1024_freepdk45 \
    icache_tag_sram_1rw0r0w_20_128_freepdk45 \
]

set macro_lefs {}
set macro_libs_slow {}
foreach m $sram_names {
    lappend macro_lefs      $PROJECT_ROOT/sram/$m/$m.lef
    lappend macro_libs_slow $PROJECT_ROOT/sram/$m/${m}_SS_0p95V_125C.lib
}

# --------------------------------------------------------------------------
# 3.  LEF files (tech LEF first)
# --------------------------------------------------------------------------
set lef_files [concat \
    [list $PDK_ROOT/rtk-tech.lef $PDK_ROOT/stdcells.lef] \
    $macro_lefs]

# --------------------------------------------------------------------------
# 4.  Liberty files per corner
# --------------------------------------------------------------------------
set lib_typical [list $PDK_ROOT/stdcells.lib]
set lib_slow    [list $PDK_ROOT/stdcells-wc.lib]
set lib_fast    [list $PDK_ROOT/stdcells-bc.lib]

foreach f [concat $lib_typical $lib_slow $lib_fast \
                  $macro_libs_slow $lef_files] {
    if {![file exists $f]} { error "Missing file: $f" }
}

# --------------------------------------------------------------------------
# 5.  Other views
# --------------------------------------------------------------------------
set verilog_stdcell $PDK_ROOT/stdcells.v
set cdl_stdcell     $PDK_ROOT/stdcells.cdl
set gds_stdcell     $PDK_ROOT/stdcells.gds
set captable_typ    $PDK_ROOT/rtk-typical.captable   ;# typical only

# --------------------------------------------------------------------------
# 6.  Genus
# --------------------------------------------------------------------------
set genus_lib_files       [concat $lib_slow $macro_libs_slow]
set genus_lib_search_path [list $PDK_ROOT]

# --------------------------------------------------------------------------
# 7.  Summary
# --------------------------------------------------------------------------
puts "INFO: FreePDK45(mflowgen) ADK loaded"
puts "INFO:   PDK_ROOT   = $PDK_ROOT"
puts "INFO:   LEF files  = $lef_files"
puts "INFO:   Slow libs  = $genus_lib_files"
