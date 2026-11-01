set root [file normalize [file join [file dirname [info script]] ..]]
if {[current_project -quiet] ne ""} {error {Use a fresh Vivado session}}
set project_dir [file join $root vivado_build]
file mkdir $project_dir
if {[file exists [file join $project_dir WYXFINALproject.xpr]]} {error {Existing build project preserved; use a fresh vivado_build directory}}
create_project WYXFINALproject $project_dir -part xc7z020clg400-1
set_property target_language Verilog [current_project]
add_files -norecurse [file join $root src ip wyx_ps_clock wyx_ps_clock.bd]
set bd [get_files wyx_ps_clock.bd]
open_bd_design $bd
validate_bd_design
save_bd_design
set_property synth_checkpoint_mode None $bd
generate_target synthesis $bd
set wrapper [make_wrapper -files $bd -top]
add_files -norecurse $wrapper
foreach folder {rtl drivers display} {
    foreach pattern {*.v *.sv} {
        set paths [glob -nocomplain [file join $root src $folder $pattern]]
        if {[llength $paths]} {add_files -norecurse $paths}
    }
}
add_files -fileset constrs_1 -norecurse [file join $root src constraints pynqz2.xdc]
set_property top wyx_final_board_top [get_filesets sources_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none [get_runs synth_1]
update_compile_order -fileset sources_1
puts {WYX_FULL_BOARD_PROJECT_READY}

