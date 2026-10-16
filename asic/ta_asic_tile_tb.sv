`timescale 1ns/1ps
// Self-checking testbench for ta_asic_tile, used on the RTL and on the
// OpenLane gate-level netlist (+define+GL). Vectors come from
// asic/tile_vectors.py: waves.hex (one line per wave: left lanes, then top
// lanes), tests.hex ({first wave, wave count} per test) and checks.hex (per
// output lane: bias, multiplier, shift, relu, expected acc, expected result).
// Prints TILE_PASS or TILE_FAIL with counts.
module ta_asic_tile_tb;
    localparam N = 8, LANES = N * N, MAX_TESTS = 64, MAX_WAVES = 8192;
    logic clk = 0, reset = 1, clear = 0, advance = 0, load = 0, start = 0, relu = 0;
    logic [8*N-1:0] left_in = 0, top_in = 0;
    logic [5:0] lane = 0, shift = 0;
    logic [31:0] bias = 0;
    logic [30:0] multiplier = 0;
    wire signed [31:0] acc_out;
    wire done;
    wire signed [7:0] result;

`ifdef GL
    ta_asic_tile dut (
`else
    ta_asic_tile #(.N(N)) dut (
`endif
        .clk, .reset, .clear, .advance, .left_in, .top_in, .load, .lane, .bias,
        .start, .multiplier, .shift, .relu, .acc_out, .done, .result);

    always #5 clk = ~clk;

    logic [16*N-1:0] waves [0:MAX_WAVES-1];
    logic [31:0] tests [0:MAX_TESTS-1];
    logic [119:0] checks [0:MAX_TESTS*LANES-1];
    integer ntests, t, w, l, wait_cycles, acc_errors = 0, result_errors = 0, lanes_checked = 0;
    logic [119:0] c;

    // Inputs change on the falling edge, so the tile samples them cleanly.
    task automatic step(input integer cycles);
        repeat (cycles) @(negedge clk);
    endtask

    initial begin
        if (!$value$plusargs("TESTS=%d", ntests)) ntests = 24;
        $readmemh("waves.hex", waves);
        $readmemh("tests.hex", tests);
        $readmemh("checks.hex", checks);
        step(3); reset = 0;
        for (t = 0; t < ntests; t = t + 1) begin
            clear = 1; step(1); clear = 0;
            for (w = 0; w < tests[t][15:0]; w = w + 1) begin
                advance = 1;
                {left_in, top_in} = waves[tests[t][31:16] + w];
                step(1);
            end
            advance = 0; left_in = 0; top_in = 0;
            step(3);                              // input register, product, last add
            for (l = 0; l < LANES; l = l + 1) begin
                c = checks[t * LANES + l];
                load = 1; lane = l; bias = c[119:88]; step(1); load = 0;
                step(1);                          // load_q, then acc_out
                if (acc_out !== c[39:8]) begin
                    acc_errors = acc_errors + 1;
                    if (acc_errors <= 5) $display("ACC_MISMATCH test=%0d lane=%0d got=%h want=%h", t, l, acc_out, c[39:8]);
                end
                start = 1; multiplier = c[86:56]; shift = c[53:48]; relu = c[40];
                step(1); start = 0;
                wait_cycles = 0;
                while (done !== 1'b1 && wait_cycles < 20) begin @(posedge clk); #1; wait_cycles = wait_cycles + 1; end
                if (done !== 1'b1 || result !== c[7:0]) begin
                    result_errors = result_errors + 1;
                    if (result_errors <= 5) $display("RESULT_MISMATCH test=%0d lane=%0d done=%b got=%h want=%h", t, l, done, result, c[7:0]);
                end
                lanes_checked = lanes_checked + 1;
                step(1);
            end
        end
        if (acc_errors == 0 && result_errors == 0)
            $display("TILE_PASS tests=%0d lanes=%0d", ntests, lanes_checked);
        else
            $display("TILE_FAIL tests=%0d lanes=%0d acc_errors=%0d result_errors=%0d", ntests, lanes_checked, acc_errors, result_errors);
        $finish;
    end
endmodule
