create_clock -name core_clock -period 20.000 [get_ports clk]
set_input_delay -clock core_clock -max 2.000 [get_ports {reset req_valid req_write req_addr[*] req_wdata[*]}]
set_input_delay -clock core_clock -min 0.000 [get_ports {reset req_valid req_write req_addr[*] req_wdata[*]}]
set_output_delay -clock core_clock -max 2.000 [get_ports {req_ready rsp_valid rsp_error rsp_rdata[*]}]
set_output_delay -clock core_clock -min 0.000 [get_ports {req_ready rsp_valid rsp_error rsp_rdata[*]}]
derive_clock_uncertainty
