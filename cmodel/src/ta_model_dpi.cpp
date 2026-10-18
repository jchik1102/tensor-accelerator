// DPI-C entry points for the scoreboard in tb/core_tb.sv. The bench creates one
// model, tells it about every reset, and asks it for the response to every
// accepted bus access, giving the clock edge it was accepted on.
#include "ta_model.hpp"

extern "C" {

void *ta_model_new(int array_n) { return new ta::Core(array_n); }

void ta_model_free(void *model) { delete static_cast<ta::Core *>(model); }

void ta_model_reset(void *model, long long cycle) {
    static_cast<ta::Core *>(model)->reset(static_cast<uint64_t>(cycle));
}

void ta_model_access(void *model, long long cycle, unsigned char write, unsigned int addr, unsigned int wdata,
                     unsigned char *error, unsigned int *rdata) {
    const ta::Response r = static_cast<ta::Core *>(model)->access(static_cast<uint64_t>(cycle), write != 0, addr, wdata);
    *error = r.error ? 1 : 0;
    *rdata = r.rdata;
}

unsigned int ta_model_job_cycles(void *model) { return static_cast<ta::Core *>(model)->job_cycles(); }

}
