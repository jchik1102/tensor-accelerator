#include "ta_model.hpp"

#include <algorithm>

namespace ta {

int8_t requantize(int32_t value, uint32_t multiplier, unsigned shift, bool relu) {
    multiplier &= 0x7fffffffu;
    shift &= 63u;
    const int64_t product = (relu && value < 0) ? 0 : int64_t(value) * int64_t(multiplier);
    const bool negative = product < 0;
    const uint64_t magnitude = negative ? uint64_t(0) - uint64_t(product) : uint64_t(product);
    const uint64_t quotient = magnitude >> shift;
    const uint64_t remainder = magnitude & ((uint64_t(1) << shift) - 1);
    const uint64_t half = shift == 0 ? 0 : uint64_t(1) << (shift - 1);
    const bool increment = shift != 0 && (remainder > half || (remainder == half && (quotient & 1)));
    const uint64_t rounded = quotient + (increment ? 1 : 0);
    if (!negative && rounded > 127) return 127;
    if (negative && rounded > 128) return -128;
    return negative ? int8_t(-int64_t(rounded)) : int8_t(rounded);
}

Descriptor Descriptor::from_words(const uint32_t *w) {
    Descriptor d;
    d.m = w[0]; d.k = w[1]; d.n = w[2]; d.src = w[3]; d.dst = w[4]; d.wb = w[5]; d.pb = w[6]; d.flags = w[7];
    return d;
}

bool Descriptor::valid() const {
    if (m < 1 || m > 32 || k < 1 || k > 1024 || n < 1 || n > 128 || flags > 1) return false;
    if (src > 8191 || dst > 8191 || wb > 65535 || pb > 1023) return false;
    const uint64_t a_end = uint64_t(src) + uint64_t(m) * k, out_end = uint64_t(dst) + uint64_t(m) * n;
    if (a_end > 8192 || out_end > 8192 || uint64_t(wb) + uint64_t(n) * k > 65536 || uint64_t(pb) + n > 1024) return false;
    return a_end <= dst || out_end <= src;   // input and output regions must not overlap
}

Core::Core(int array_n)
    : n_(array_n), a_(8192, 0), w_(65536, 0), p_(3072, 0), d_(4096, 0) {}

bool Core::busy(uint64_t cycle) const {
    return running_ && cycle > start_ && cycle - start_ <= job_cycles_;
}

uint64_t Core::idle_from() const { return start_ + job_cycles_ + 1; }

uint32_t Core::cycles_at(uint64_t cycle) const {
    if (!running_) return cycles_;
    return uint32_t(std::min<uint64_t>(cycle - start_ - 1, job_cycles_));
}

uint8_t Core::layer_at(uint64_t cycle) const {
    if (!running_) return layer_;
    uint8_t layer = 0;
    for (const LayerStep &s : layer_steps_)
        if (cycle - start_ > s.offset) layer = s.layer;
    return layer;
}

uint32_t Core::status(uint64_t cycle) const {
    return (error_sticky_ ? 4u : 0u) | (done_ ? 2u : 0u) | (busy(cycle) ? 1u : 0u);
}

// Bring the model up to an edge: once the job's last busy edge has passed,
// its stores, flags and registers are what the core holds.
void Core::settle(uint64_t cycle) {
    if (!running_ || busy(cycle) || cycle <= start_) return;
    for (; stores_applied_ < stores_.size(); stores_applied_++) {
        const Store &s = stores_[stores_applied_];
        a_[s.a_addr] = s.value;
        d_[s.d_addr] = s.acc;
    }
    layer_ = layer_at(cycle);
    cycles_ = job_cycles_;
    if (job_error_) flag_error(job_error_code_);
    else done_ = true;
    running_ = false;
}

void Core::reset(uint64_t cycle) {
    settle(cycle);
    if (running_) {
        // Stores made on edges before the reset happened; the rest never do.
        for (const Store &s : stores_)
            if (s.offset < cycle - start_) { a_[s.a_addr] = s.value; d_[s.d_addr] = s.acc; }
        running_ = false;
    }
    stores_.clear();
    stores_applied_ = 0;
    layer_steps_.clear();
    desc_.fill(0);
    layer_count_ = 0; error_code_ = 0; done_ = false; error_sticky_ = false; cycles_ = 0; layer_ = 0;
    job_cycles_ = 0;
}

// One layer, following the RTL's states; t counts state cycles from the start
// command, so a store in state cycle t lands on edge start + t.
void Core::layer_cycles(const Descriptor &d, std::vector<int8_t> &a, uint64_t &t, bool &failed) {
    t += 2;                                        // DESC, CHECK_DESC
    if (!d.valid()) { failed = true; job_error_code_ = 3; return; }
    const uint32_t N = uint32_t(n_);
    const uint32_t load = (d.k + N - 1) / N;       // LOAD_A/LOAD_B cycles per row
    const int32_t bound = int32_t(0x7fffffffu - d.k * 16384u);
    for (uint32_t row_base = 0; row_base < d.m; row_base += N) {
        for (uint32_t col_base = 0; col_base < d.n; col_base += N) {
            const uint32_t rows = std::min(N, d.m - row_base), cols = std::min(N, d.n - col_base);
            // TILE_CLEAR, LOAD_A, DRAIN_A, LOAD_B, DRAIN_B, STREAM, STREAM_DRAIN, MAC_DRAIN
            t += 1 + rows * load + 1 + cols * load + 1 + (d.k + 2 * N - 2) + 1 + 1;
            for (uint32_t lane = 0; lane < N * N; lane++) {
                const uint32_t row = row_base + lane / N, col = col_base + lane % N;
                if (row >= d.m || col >= d.n) { t += 2; continue; }   // P_BIAS, NEXT_OUTPUT
                const uint32_t channel = (d.pb + col) * 3;
                const uint32_t bias = p_[channel], mult = p_[channel + 1], shift = p_[channel + 2];
                t += 6;                            // P_BIAS .. CAP_SHIFT
                if (mult == 0 || (mult >> 31) || shift > 62 || int32_t(bias) > bound || int32_t(bias) < -bound) {
                    failed = true; job_error_code_ = 4; return;
                }
                int32_t sum = 0;
                for (uint32_t i = 0; i < d.k; i++)
                    sum += int32_t(a[d.src + row * d.k + i]) * int32_t(w_[d.wb + col * d.k + i]);
                const uint32_t acc = uint32_t(sum) + bias;
                const int8_t q = requantize(int32_t(acc), mult, shift, d.flags & 1);
                t += 1 + 5 + 1;                    // Q_START, Q_WAIT (the requantizer's 5 cycles), STORE
                const uint32_t out = row * d.n + col;
                stores_.push_back({t, uint16_t(d.dst + out), q, uint16_t(out), acc});
                a[d.dst + out] = q;                // later layers read this layer's outputs
                t += 1;                            // NEXT_OUTPUT
            }
            t += 1;                                // NEXT_TILE
        }
    }
}

void Core::run_job() {
    stores_.clear();
    stores_applied_ = 0;
    layer_steps_.clear();
    job_error_ = false;
    job_error_code_ = 0;
    std::vector<int8_t> a = a_;
    uint64_t t = 0;
    for (uint32_t layer = 0; layer < layer_count_; layer++) {
        bool failed = false;
        layer_cycles(Descriptor::from_words(&desc_[8 * layer]), a, t, failed);
        if (failed) { job_error_ = true; break; }
        t += 1;                                    // NEXT_LAYER
        if (layer + 1 < layer_count_) layer_steps_.push_back({t, uint8_t(layer + 1)});
    }
    job_cycles_ = uint32_t(t);
}

Response Core::access(uint64_t cycle, bool write, uint32_t addr, uint32_t wdata) {
    settle(cycle);
    Response r;
    const bool sel_a = addr >= 0x10000 && addr < 0x18000, sel_w = addr >= 0x20000 && addr < 0x60000;
    const bool sel_p = addr >= 0x1000 && addr < 0x4000, sel_d = addr >= 0x60000 && addr < 0x64000;
    const bool sel_desc = addr >= 0x100 && addr < 0x200;
    if (addr & 3) { r.error = true; flag_error(1); return r; }
    if (write && addr == 8 && wdata == 4) { reset(cycle); return r; }   // soft reset, even while busy
    if (busy(cycle) && (write || sel_a || sel_w || sel_p || sel_d || sel_desc)) {
        r.error = true; flag_error(2); return r;
    }
    if (sel_desc) {
        if (write) desc_[(addr >> 2) & 63] = wdata; else r.rdata = desc_[(addr >> 2) & 63];
    } else if (sel_a) {
        const uint32_t i = (addr - 0x10000) >> 2;
        if (write) a_[i] = int8_t(wdata & 0xff); else r.rdata = uint32_t(int32_t(a_[i]));
    } else if (sel_w) {
        const uint32_t i = (addr - 0x20000) >> 2;
        if (write) w_[i] = int8_t(wdata & 0xff); else r.rdata = uint32_t(int32_t(w_[i]));
    } else if (sel_p) {
        const uint32_t i = (addr - 0x1000) >> 2;
        if (write) p_[i] = wdata; else r.rdata = p_[i];
    } else if (sel_d && !write) {
        r.rdata = d_[(addr - 0x60000) >> 2];
    } else if (write) {
        if (addr == 8) {
            if (wdata == 2) { done_ = false; error_sticky_ = false; error_code_ = 0; }
            else if (wdata == 1 && !done_ && !error_sticky_ && layer_count_ >= 1 && layer_count_ <= 8) {
                cycles_ = 0; layer_ = 0; running_ = true; start_ = cycle;
                run_job();
            } else { r.error = true; flag_error(3); }
        } else if (addr == 12) {
            layer_count_ = wdata;
        } else { r.error = true; flag_error(1); }
    } else {
        switch (addr) {
            case 0: r.rdata = ID; break;
            case 4: r.rdata = status(cycle); break;
            case 12: r.rdata = layer_count_; break;
            case 16: r.rdata = error_code_; break;
            case 20: r.rdata = cycles_at(cycle); break;
            case 24: r.rdata = layer_at(cycle); break;
            default: r.error = true; flag_error(1); break;
        }
    }
    return r;
}

}  // namespace ta
