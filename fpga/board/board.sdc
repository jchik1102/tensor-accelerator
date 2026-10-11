create_clock -name board_clock -period 20.000 [get_ports MAX10_CLK1_50]
derive_pll_clocks
set_false_path -from [get_ports KEY0]
derive_clock_uncertainty
set_false_path -to [get_ports {HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]
