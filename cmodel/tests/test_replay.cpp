// Replays artifacts/vectors/core.txt (the bus script tb/core_tb.sv runs on the
// RTL, written by host/ta/vectors.py from the Python model) on the C++ model,
// with no RTL: every expected read value and error flag must match. Time
// advances a few edges per access; "P" (poll until idle) jumps to the end of
// the job, and "H" (reset while the RTL is in a given state) resets at once.
#include <cstdio>
#include <fstream>
#include <string>

#include "check.hpp"
#include "ta_model.hpp"

int main(int argc, char **argv) {
    if (argc != 3) { std::fprintf(stderr, "usage: test_replay <core.txt> <array_n>\n"); return 2; }
    ta::Core core(std::stoi(argv[2]));
    std::ifstream in(argv[1]);
    CHECK(in.good());
    uint64_t cycle = 1;
    core.reset(cycle);
    std::string line;
    int lines = 0, reads = 0, jobs = 0;
    char op[8];
    unsigned a, b, c, d;
    while (std::getline(in, line)) {
        if (std::sscanf(line.c_str(), "%7s %x %x %x %x", op, &a, &b, &c, &d) != 5) continue;
        lines++;
        const char cmd = op[0];
        if (cmd == 'Z' || cmd == 'H') { cycle += 4; core.reset(cycle); cycle += 4; continue; }
        if (cmd == 'D') { cycle += a; continue; }
        if (cmd == 'C' || cmd == 'O') continue;
        if (cmd == 'P') {
            if (core.idle_from() > cycle) cycle = core.idle_from();
            cycle += 3;
            const ta::Response r = core.access(cycle, false, a, 0);
            CHECK(!r.error);
            if (r.rdata != b) std::fprintf(stderr, "line %d: status %x, expected %x\n", lines, r.rdata, b);
            CHECK_EQ(r.rdata, b);
            jobs++;
            continue;
        }
        if (cmd == 'T') { cycle += 3; core.access(cycle, false, 20, 0); continue; }
        cycle += 3;
        const bool write = cmd == 'W';
        const ta::Response r = core.access(cycle, write, a, write ? b : 0);
        if (r.error != bool(c & 1)) std::fprintf(stderr, "line %d: error %d, expected %u\n", lines, r.error, c & 1);
        CHECK_EQ(r.error, bool(c & 1));
        if (cmd == 'R') {
            if (r.rdata != b) std::fprintf(stderr, "line %d: read %05x = %08x, expected %08x\n", lines, a, r.rdata, b);
            CHECK_EQ(r.rdata, b);
            reads++;
        }
    }
    std::printf("replayed %d lines: %d reads, %d jobs polled\n", lines, reads, jobs);
    CHECK(reads > 1000);
    return check::finish("test_replay");
}
