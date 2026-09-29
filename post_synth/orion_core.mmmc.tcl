#################################################################################
#
# Created by Genus(TM) Synthesis Solution 20.11-s111_1 on Tue Sep 29 11:08:00 IST 2026
#
#################################################################################

## library_sets
create_library_set -name default_emulate_libset_max \
    -timing { /home/stu7/Documents/orion-rv/workdir/../pdk/Nangate45/NangateOpenCellLibrary_PDKv1_3_v2010_12/Front_End/Liberty/CCS/NangateOpenCellLibrary_slow_ccs.lib \
              /home/stu7/Documents/orion-rv/workdir/../pdk/Nangate45/NangateOpenCellLibrary_PDKv1_3_v2010_12/Low_Power/Front_End/Liberty/CCS/LowPowerOpenCellLibrary_slow_ccs.lib }

## opcond
create_opcond -name default_emulate_opcond \
    -process 1.0 \
    -voltage 0.949999 \
    -temperature 125.0

## timing_condition
create_timing_condition -name default_emulate_timing_cond_max \
    -opcond default_emulate_opcond \
    -library_sets { default_emulate_libset_max }

## rc_corner
create_rc_corner -name default_emulate_rc_corner \
	-cap_table /home/stu7/Documents/orion-rv/pdk/Nangate45/NangateOpenCellLibrary_PDKv1_3_v2010_12/Back_End/qrc/NangateOpenCellLibrary.captable \
    -temperature 125.0 \
    -pre_route_res 1.0 \
    -pre_route_cap 1.0 \
    -pre_route_clock_res 0.0 \
    -pre_route_clock_cap 0.0 \
    -post_route_res {1.0 1.0 1.0} \
    -post_route_cap {1.0 1.0 1.0} \
    -post_route_cross_cap {1.0 1.0 1.0} \
    -post_route_clock_res {1.0 1.0 1.0} \
    -post_route_clock_cap {1.0 1.0 1.0}

## delay_corner
create_delay_corner -name default_emulate_delay_corner \
    -early_timing_condition { default_emulate_timing_cond_max } \
    -late_timing_condition { default_emulate_timing_cond_max } \
    -early_rc_corner default_emulate_rc_corner \
    -late_rc_corner default_emulate_rc_corner

## constraint_mode
create_constraint_mode -name default_emulate_constraint_mode \
    -sdc_files { ./orion_core.default_emulate_constraint_mode.sdc }

## analysis_view
create_analysis_view -name default_emulate_view \
    -constraint_mode default_emulate_constraint_mode \
    -delay_corner default_emulate_delay_corner

## set_analysis_view
set_analysis_view -setup { default_emulate_view } \
                  -hold { default_emulate_view }
