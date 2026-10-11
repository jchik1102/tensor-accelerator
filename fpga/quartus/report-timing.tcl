package require ::quartus::project
package require ::quartus::sta
project_open [lindex $quartus(args) 0]
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 20 -detail full_path -file critical-paths.rpt
report_ucp -file unconstrained-paths.rpt
delete_timing_netlist
project_close
