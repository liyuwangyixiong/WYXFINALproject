set root [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $root vivado_build]
set_param general.maxThreads 4
if {[current_project -quiet] eq ""} {
    if {![file exists [file join $project_dir WYXFINALproject.xpr]]} {
        source [file join $root build create_project.tcl]
    } else {
        open_project [file join $project_dir WYXFINALproject.xpr]
    }
}
if {[file normalize [get_property DIRECTORY [current_project]]] ne $project_dir} {error {Wrong project open}}
file mkdir [file join $root build reports]
file mkdir [file join $root board]
set reports [file join $root build reports]
reset_run impl_1
reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%" || [string match -nocase *error* [get_property STATUS [get_runs synth_1]]]} {error "Synthesis failed: [get_property STATUS [get_runs synth_1]]"}
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%" || [string match -nocase *error* [get_property STATUS [get_runs impl_1]]]} {error "Implementation/bitstream failed: [get_property STATUS [get_runs impl_1]]"}
open_run impl_1
report_timing_summary -report_unconstrained -file [file join $reports timing.rpt]
report_drc -file [file join $reports drc.rpt]
report_utilization -file [file join $reports utilization.rpt]
report_cdc -details -file [file join $reports cdc.rpt]
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {![llength $setup] || ![llength $hold]} {error {No timing paths available}}
set wns [get_property SLACK $setup]
set whs [get_property SLACK $hold]
if {$wns<0 || $whs<0} {error "Timing failed: WNS=$wns WHS=$whs"}
set bad_drc [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $bad_drc]} {error "DRC failed: $bad_drc"}
set bitfile [file join [get_property DIRECTORY [get_runs impl_1]] wyx_final_board_top.bit]
if {![file exists $bitfile]} {error "Implementation completed without bitstream: $bitfile"}
file copy -force $bitfile [file join $root board wyxfinalproject.bit]
write_checkpoint -force [file join $root vivado_build wyxfinalproject_routed.dcp]
set f [open [file join $reports result.txt] w]
puts $f "VIVADO_BUILD_PASS version=[version -short] part=[get_property PART [current_project]] WNS=$wns WHS=$whs"
close $f
puts "WYX_FULL_BOARD_BIT_READY WNS=$wns WHS=$whs"
