// C++ model of rtl/ta_core.sv at the bus-transaction level.
//
// The model takes the same 32-bit register and memory accesses as the RTL and
// answers each with the same error flag and read data. It is bit-exact for
// the arithmetic (INT8 matrix products, INT32 bias, the requantizer's
// round-half-to-even and saturation) and cycle-exact for the job length: a
// job's length is computed from the RTL's state sequence, so the model knows
// on which clock edge the core stops being busy, what the CYCLES and LAYER
// registers read at any edge, and which output stores had happened when a
// reset cut a job short.
//
// Cycle numbers are clock edges. access(cycle, ...) is an access accepted on
// that edge; reset(cycle) is a reset (hard, or the soft reset command) that
// acts on that edge.
#pragma once

#include <array>
#include <cstdint>
#include <vector>

namespace ta {

// ta_requant: value * multiplier, rounded to nearest with ties to even on the
// magnitude, shifted right by shift, saturated to INT8; with relu, negative
// values give 0. multiplier is the RTL's 31-bit field, shift its 6-bit field.
int8_t requantize(int32_t value, uint32_t multiplier, unsigned shift, bool relu);

struct Response {
    bool error = false;
    uint32_t rdata = 0;
};

// One layer descriptor, as the core reads it from desc[8*layer .. 8*layer+7].
struct Descriptor {
    uint32_t m = 0, k = 0, n = 0, src = 0, dst = 0, wb = 0, pb = 0, flags = 0;
    static Descriptor from_words(const uint32_t *words);
    bool valid() const;   // the checks in the RTL's CHECK_DESC state
};

class Core {
public:
    static constexpr uint32_t ID = 0x54413031;   // "TA01"
    explicit Core(int array_n);

    void reset(uint64_t cycle);                    // hard reset or soft reset acting on this edge
    Response access(uint64_t cycle, bool write, uint32_t addr, uint32_t wdata);

    bool busy(uint64_t cycle) const;               // as an access on this edge sees it
    uint64_t idle_from() const;                    // first edge that sees the last job finished
    uint32_t job_cycles() const { return job_cycles_; }
    int array_n() const { return n_; }

private:
    struct Store {          // one output store, made on edge start + offset
        uint64_t offset;
        uint16_t a_addr;    // INT8 result into the A memory
        int8_t value;
        uint16_t d_addr;    // INT32 accumulator into the D memory
        uint32_t acc;
    };
    struct LayerStep {      // the LAYER register changes on edge start + offset
        uint64_t offset;
        uint8_t layer;
    };

    void settle(uint64_t cycle);     // apply what the running job has done before this edge
    void run_job();                  // compute the whole job from the current memories
    void layer_cycles(const Descriptor &d, std::vector<int8_t> &a, uint64_t &t, bool &failed);
    uint32_t cycles_at(uint64_t cycle) const;
    uint8_t layer_at(uint64_t cycle) const;
    uint32_t status(uint64_t cycle) const;
    void flag_error(uint32_t code) { error_sticky_ = true; error_code_ = code; }

    int n_;
    std::vector<int8_t> a_, w_;
    std::vector<uint32_t> p_, d_;
    std::array<uint32_t, 64> desc_{};
    uint32_t layer_count_ = 0, error_code_ = 0;
    bool done_ = false, error_sticky_ = false;
    uint32_t cycles_ = 0;
    uint8_t layer_ = 0;

    // The job in flight (or the last one), with its outcome.
    bool running_ = false;
    uint64_t start_ = 0;
    uint32_t job_cycles_ = 0;
    bool job_error_ = false;
    uint32_t job_error_code_ = 0;
    std::vector<Store> stores_;
    std::size_t stores_applied_ = 0;
    std::vector<LayerStep> layer_steps_;
};

}  // namespace ta
