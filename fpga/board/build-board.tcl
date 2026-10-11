package require ::quartus::project
package require ::quartus::flow
set root [file normalize [file join [file dirname [info script]] ../..]]
project_new de10_lite -overwrite
set array_n [lindex $quartus(args) 0]
set core_mhz [lindex $quartus(args) 1]
if {$array_n eq ""} {set array_n 4}
if {$core_mhz eq ""} {set core_mhz 50}
set_parameter -name ARRAY_N $array_n
set_parameter -name CORE_MHZ $core_mhz
set_global_assignment -name FAMILY "MAX 10"
set_global_assignment -name DEVICE 10M50DAF484C7G
set_global_assignment -name TOP_LEVEL_ENTITY de10_lite_top
foreach source {ta_pe ta_array ta_requant ta_ram ta_vector_ram ta_core} {
    set_global_assignment -name SYSTEMVERILOG_FILE [file join $root rtl $source.sv]
}
foreach source {ta_avalon_adapter ta_hex_decoder de10_lite_top} {
    set_global_assignment -name SYSTEMVERILOG_FILE [file join $root fpga board $source.sv]
}
set_global_assignment -name QIP_FILE [file join $root artifacts board ta_jtag synthesis ta_jtag.qip]
set_global_assignment -name SDC_FILE [file join $root fpga board board.sdc]
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
set_global_assignment -name NUM_PARALLEL_PROCESSORS 4
set_global_assignment -name SEED 1
set_global_assignment -name RESERVE_ALL_UNUSED_PINS "AS INPUT TRI-STATED"
set_location_assignment PIN_P11 -to MAX10_CLK1_50
set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to MAX10_CLK1_50
set_location_assignment PIN_B8 -to KEY0
set_instance_assignment -name IO_STANDARD "3.3 V SCHMITT TRIGGER" -to KEY0
set hex_pins {
    {C14 E15 C15 C16 E16 D17 C17 D15}
    {C18 D18 E18 B16 A17 A18 B17 A16}
    {B20 A20 B19 A21 B21 C22 B22 A19}
    {F21 E22 E21 C19 C20 D19 E17 D22}
    {F18 E20 E19 J18 H19 F19 F20 F17}
    {J20 K20 L18 N18 M20 N19 N20 L19}
}
for {set digit 0} {$digit < 6} {incr digit} {
    for {set bit 0} {$bit < 8} {incr bit} {
        set port [format {HEX%d[%d]} $digit $bit]
        set_location_assignment PIN_[lindex $hex_pins $digit $bit] -to $port
        set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to $port
    }
}
execute_flow -compile
project_close
