package require ::quartus::project
package require ::quartus::flow
set root [file normalize [file join [file dirname [info script]] ../..]]
project_new ta_core -overwrite
set array_n [lindex $quartus(args) 0]
if {$array_n eq ""} {set array_n 4}
set_parameter -name ARRAY_N $array_n
set_global_assignment -name FAMILY "MAX 10"
set_global_assignment -name DEVICE 10M50DAF484C7G
set_global_assignment -name TOP_LEVEL_ENTITY ta_core
foreach source {ta_pe ta_array ta_requant ta_ram ta_vector_ram ta_core} {
    set_global_assignment -name SYSTEMVERILOG_FILE [file join $root rtl $source.sv]
}
set_global_assignment -name SDC_FILE [file join $root fpga quartus core.sdc]
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
set_global_assignment -name SEED 1
foreach signal {reset req_valid req_write req_addr[*] req_wdata[*] req_ready rsp_valid rsp_error rsp_rdata[*]} {
    set_instance_assignment -name VIRTUAL_PIN ON -to $signal
}
execute_flow -compile
project_close
