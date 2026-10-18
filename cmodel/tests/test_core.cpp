// Directed tests of the bus model: register map, error codes, a small layer
// against a reference computed here, busy handling, the cycle count, two
// layers chained, and resets in the middle of a job.
#include <cstdio>
#include <vector>

#include "check.hpp"
#include "ta_model.hpp"

namespace {

constexpr uint32_t CTRL = 8, STATUS = 4, LAYERS = 12, ERROR = 16, CYCLES = 20, LAYER = 24;
constexpr uint32_t A = 0x10000, W = 0x20000, P = 0x1000, D = 0x60000, DESC = 0x100;

struct Bus {
    ta::Core core;
    uint64_t cycle = 10;
    explicit Bus(int n) : core(n) { core.reset(1); }
    ta::Response access(bool write, uint32_t addr, uint32_t data = 0) {
        cycle += 3;                                   // the RTL accepts at most every other edge
        return core.access(cycle, write, addr, data);
    }
    void wr(uint32_t addr, uint32_t data, bool error = false) { CHECK_EQ(access(true, addr, data).error, error); }
    uint32_t rd(uint32_t addr, bool error = false) {
        const ta::Response r = access(false, addr);
        CHECK_EQ(r.error, error);
        return r.rdata;
    }
    void wait_idle() { if (core.idle_from() > cycle) cycle = core.idle_from(); }
};

struct Layer {
    uint32_t m, k, n, src, dst, wb, pb, relu;
    std::vector<int8_t> a, w;
    std::vector<int32_t> bias;
    std::vector<uint32_t> mult, shift;
};

uint32_t lcg = 12345;
int8_t random_int8() { lcg = lcg * 1103515245u + 12345u; return int8_t(lcg >> 16); }

Layer make_layer(uint32_t m, uint32_t k, uint32_t n, uint32_t src, uint32_t dst, uint32_t wb, uint32_t pb, bool relu) {
    Layer l{m, k, n, src, dst, wb, pb, relu, {}, {}, {}, {}, {}};
    for (uint32_t i = 0; i < m * k; i++) l.a.push_back(random_int8());
    for (uint32_t i = 0; i < n * k; i++) l.w.push_back(random_int8());
    for (uint32_t j = 0; j < n; j++) {
        l.bias.push_back(int32_t(random_int8()) * 3);
        l.mult.push_back(1 + (uint32_t(uint8_t(random_int8())) << 6));
        l.shift.push_back(12 + j % 5);
    }
    return l;
}

void load(Bus &bus, const Layer &l, int index, bool inputs = true) {
    if (inputs) for (uint32_t i = 0; i < l.a.size(); i++) bus.wr(A + 4 * (l.src + i), uint32_t(l.a[i]));
    for (uint32_t i = 0; i < l.w.size(); i++) bus.wr(W + 4 * (l.wb + i), uint32_t(l.w[i]));
    for (uint32_t j = 0; j < l.n; j++) {
        bus.wr(P + 12 * (l.pb + j), uint32_t(l.bias[j]));
        bus.wr(P + 12 * (l.pb + j) + 4, l.mult[j]);
        bus.wr(P + 12 * (l.pb + j) + 8, l.shift[j]);
    }
    const uint32_t words[8] = {l.m, l.k, l.n, l.src, l.dst, l.wb, l.pb, l.relu};
    for (int i = 0; i < 8; i++) bus.wr(DESC + 32 * index + 4 * i, words[i]);
}

// Reference: the layer computed directly from its definition.
void reference(const Layer &l, const std::vector<int8_t> &a, std::vector<int8_t> &out, std::vector<int32_t> &acc) {
    for (uint32_t r = 0; r < l.m; r++)
        for (uint32_t c = 0; c < l.n; c++) {
            int32_t sum = 0;
            for (uint32_t i = 0; i < l.k; i++) sum += int32_t(a[r * l.k + i]) * int32_t(l.w[c * l.k + i]);
            acc.push_back(sum + l.bias[c]);
            out.push_back(ta::requantize(sum + l.bias[c], l.mult[c], l.shift[c], l.relu));
        }
}

// The RTL's job length for one layer (see ta_core.sv's state machine).
uint64_t layer_length(uint32_t N, uint32_t m, uint32_t k, uint32_t n) {
    uint64_t t = 2;
    const uint32_t load = (k + N - 1) / N;
    for (uint32_t rb = 0; rb < m; rb += N)
        for (uint32_t cb = 0; cb < n; cb += N) {
            const uint32_t rows = m - rb < N ? m - rb : N, cols = n - cb < N ? n - cb : N;
            t += 5 + (rows + cols) * load + k + 2 * N - 2;
            t += uint64_t(rows * cols) * 14 + (N * N - rows * cols) * 2 + 1;
        }
    return t + 1;
}

}  // namespace

int main() {
    for (int N : {4, 8}) {
        Bus bus(N);
        CHECK_EQ(bus.rd(0), ta::Core::ID);
        CHECK_EQ(bus.rd(STATUS), 0u);
        // Bus errors and their codes.
        bus.rd(3, true);                CHECK_EQ(bus.rd(ERROR), 1u);
        bus.wr(CTRL, 2);                CHECK_EQ(bus.rd(STATUS), 0u);
        bus.rd(CTRL, true);             CHECK_EQ(bus.rd(ERROR), 1u);
        bus.wr(CTRL, 2);
        bus.wr(0, 7, true);             CHECK_EQ(bus.rd(STATUS), 4u);
        bus.wr(CTRL, 2);
        bus.wr(D, 5, true);             bus.wr(CTRL, 2);   // D is read-only over the bus
        bus.rd(0x90000, true);          bus.wr(CTRL, 2);
        bus.wr(CTRL, 1, true);          CHECK_EQ(bus.rd(ERROR), 3u);   // no layers set
        bus.wr(CTRL, 2);
        bus.wr(CTRL, 9, true);          CHECK_EQ(bus.rd(ERROR), 3u);
        bus.wr(CTRL, 2);
        bus.wr(A + 4, 0x1ff);           CHECK_EQ(bus.rd(A + 4), 0xffffffffu);   // stored as INT8, read sign-extended
        bus.wr(W + 8, 0x7f);            CHECK_EQ(bus.rd(W + 8), 0x7fu);
        bus.wr(P + 4, 0xdeadbeef);      CHECK_EQ(bus.rd(P + 4), 0xdeadbeefu);

        // One layer that needs several tiles in both directions.
        Layer l = make_layer(N + 3, 21, 2 * N + 1, 5, 4096, 7, 3, true);
        load(bus, l, 0);
        bus.wr(LAYERS, 1);
        bus.wr(CTRL, 1);
        const uint64_t start = bus.cycle;
        CHECK_EQ(bus.core.job_cycles(), layer_length(uint32_t(N), l.m, l.k, l.n));
        CHECK_EQ(bus.rd(STATUS), 1u);                      // busy
        const uint32_t c1 = bus.rd(CYCLES);
        CHECK_EQ(uint64_t(c1), bus.cycle - start - 1);     // the counter advances with the clock
        bus.rd(A, true);                                   // memory reads are refused while busy
        bus.wr(LAYERS, 1, true);                           // so are register writes
        CHECK_EQ(bus.rd(ERROR), 2u);
        bus.wait_idle();
        CHECK_EQ(bus.rd(STATUS), 6u);                      // done, with the sticky error from above
        CHECK_EQ(bus.rd(ERROR), 2u);
        CHECK_EQ(uint64_t(bus.rd(CYCLES)), uint64_t(bus.core.job_cycles()));
        std::vector<int8_t> out; std::vector<int32_t> acc;
        reference(l, l.a, out, acc);
        for (uint32_t i = 0; i < out.size(); i++) {
            CHECK_EQ(int32_t(bus.rd(A + 4 * (l.dst + i))), int32_t(out[i]));
            CHECK_EQ(int32_t(bus.rd(D + 4 * i)), acc[i]);
        }
        bus.wr(CTRL, 1, true);                             // done must be cleared before the next start
        CHECK_EQ(bus.rd(ERROR), 3u);
        bus.wr(CTRL, 2);

        // Two layers: the second reads the first one's outputs.
        Layer l1 = make_layer(3, 9, 6, 0, 100, 0, 0, false);
        Layer l2 = make_layer(3, 6, 4, 100, 200, 500, 50, true);
        load(bus, l1, 0);
        load(bus, l2, 1, false);
        bus.wr(LAYERS, 2);
        bus.wr(CTRL, 1);
        const uint64_t start2 = bus.cycle;
        const uint64_t first = layer_length(uint32_t(N), 3, 9, 6);
        CHECK_EQ(uint64_t(bus.core.job_cycles()), first + layer_length(uint32_t(N), 3, 6, 4));
        CHECK_EQ(bus.rd(LAYER), 0u);
        bus.cycle = start2 + first + 1;                    // the edge after the first NEXT_LAYER
        CHECK_EQ(bus.core.access(bus.cycle, false, LAYER, 0).rdata, 1u);
        bus.wait_idle();
        CHECK_EQ(bus.rd(STATUS), 2u);
        std::vector<int8_t> o1, o2; std::vector<int32_t> a1, a2;
        reference(l1, l1.a, o1, a1);
        reference(l2, o1, o2, a2);
        for (uint32_t i = 0; i < o2.size(); i++) CHECK_EQ(int32_t(bus.rd(A + 4 * (200 + i))), int32_t(o2[i]));
        for (uint32_t i = 0; i < a2.size(); i++) CHECK_EQ(int32_t(bus.rd(D + 4 * i)), a2[i]);

        // Invalid descriptor: error 3 after DESC and CHECK_DESC.
        bus.wr(CTRL, 2);
        bus.wr(DESC + 4, 1025);
        bus.wr(LAYERS, 1);
        bus.wr(CTRL, 1);
        CHECK_EQ(bus.core.job_cycles(), 2u);
        bus.wait_idle();
        CHECK_EQ(bus.rd(STATUS), 4u);
        CHECK_EQ(bus.rd(ERROR), 3u);

        // Bad parameters for the second output: error 4, the first output is stored.
        bus.wr(CTRL, 2);
        Layer l3 = make_layer(1, 4, 2, 0, 300, 0, 0, false);
        l3.mult[1] = 0;
        load(bus, l3, 0);
        bus.wr(A + 4 * 300, 55); bus.wr(A + 4 * 301, 66);
        bus.wr(CTRL, 1);
        bus.wait_idle();
        CHECK_EQ(bus.rd(ERROR), 4u);
        std::vector<int8_t> o3; std::vector<int32_t> a3;
        l3.mult[1] = 1;
        reference(l3, l3.a, o3, a3);
        CHECK_EQ(int32_t(bus.rd(A + 4 * 300)), int32_t(o3[0]));
        CHECK_EQ(int32_t(bus.rd(A + 4 * 301)), 66);

        // Soft reset in the middle of a job: stores already made stay, the rest never happen.
        bus.wr(CTRL, 2);
        Layer l4 = make_layer(N, 64, N, 0, 1000, 0, 0, false);
        load(bus, l4, 0);
        for (uint32_t i = 0; i < l4.m * l4.n; i++) bus.wr(A + 4 * (1000 + i), 99);
        bus.wr(LAYERS, 1);
        bus.wr(CTRL, 1);
        const uint64_t start4 = bus.cycle;
        // The first store lands on the first STORE edge: 2 + tile set-up + 14 output cycles - NEXT_OUTPUT.
        const uint64_t first_store = 2 + 5 + 2 * N * ((64 + N - 1) / N) + 64 + 2 * N - 2 + 13;
        bus.cycle = start4 + first_store + 1 - 3;          // so the next access (3 edges on) is just after it
        bus.wr(CTRL, 4);                                   // soft reset
        CHECK_EQ(bus.rd(STATUS), 0u);
        CHECK_EQ(bus.rd(LAYERS), 0u);
        CHECK_EQ(bus.rd(DESC), 0u);
        std::vector<int8_t> o4; std::vector<int32_t> a4;
        reference(l4, l4.a, o4, a4);
        CHECK_EQ(int32_t(bus.rd(A + 4 * 1000)), int32_t(o4[0]));
        CHECK_EQ(int32_t(bus.rd(A + 4 * 1001)), 99);
        std::printf("array %dx%d: one-layer job %u cycles\n", N, N, unsigned(layer_length(uint32_t(N), l.m, l.k, l.n)));
    }
    return check::finish("test_core");
}
