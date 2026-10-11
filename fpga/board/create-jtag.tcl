package require -exact qsys 24.1
create_system ta_jtag
set_project_property DEVICE_FAMILY "MAX 10"
set_project_property DEVICE 10M50DAF484C7G
add_instance jtag altera_jtag_avalon_master 24.1
set_instance_parameter_value jtag USE_PLI 0
set_instance_parameter_value jtag FAST_VER 0
add_interface clk clock sink
set_interface_property clk EXPORT_OF jtag.clk
add_interface reset reset sink
set_interface_property reset EXPORT_OF jtag.clk_reset
add_interface master avalon master
set_interface_property master EXPORT_OF jtag.master
add_interface master_reset reset source
set_interface_property master_reset EXPORT_OF jtag.master_reset
save_system ta_jtag.qsys
