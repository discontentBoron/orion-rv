################################################################################
#
# Init setup file
# Created by Genus(TM) Synthesis Solution on 09/29/2026 11:08:16
#
################################################################################

      if { ![is_common_ui_mode] } {
        error "This script must be loaded into an 'innovus -stylus' session."
      }
    


read_mmmc ./orion_core.mmmc.tcl

read_physical -lefs { /home/stu7/Documents/orion-rv/pdk/Nangate45/NangateOpenCellLibrary_PDKv1_3_v2010_12/Back_End/lef/NangateOpenCellLibrary.tech.lef \
					  /home/stu7/Documents/orion-rv/pdk/Nangate45/NangateOpenCellLibrary_PDKv1_3_v2010_12/Back_End/lef/NangateOpenCellLibrary.macro.lef }


read_netlist ./orion_core.v

set_db init_power_nets VDD
set_db init_ground_nets VSS

init_design
