// The model's requantizer against artifacts/vectors/quant.txt, the cases
// host/ta/vectors.py writes from the Python reference (host/ta/numeric.py),
// plus a few cases worked by hand.
#include <cstdio>
#include <fstream>
#include <string>

#include "check.hpp"
#include "ta_model.hpp"

int main(int argc, char **argv) {
    if (argc != 2) { std::fprintf(stderr, "usage: test_requant <quant.txt>\n"); return 2; }
    // Round half to even on the magnitude, symmetric for negatives.
    CHECK_EQ(ta::requantize(3, 1, 1, false), 2);      // 1.5 -> 2
    CHECK_EQ(ta::requantize(5, 1, 1, false), 2);      // 2.5 -> 2
    CHECK_EQ(ta::requantize(-3, 1, 1, false), -2);    // -1.5 -> -2
    CHECK_EQ(ta::requantize(-5, 1, 1, false), -2);    // -2.5 -> -2
    CHECK_EQ(ta::requantize(7, 1, 2, false), 2);      // 1.75 -> 2
    CHECK_EQ(ta::requantize(1000, 1, 0, false), 127); // saturation
    CHECK_EQ(ta::requantize(-1000, 1, 0, false), -128);
    CHECK_EQ(ta::requantize(-128, 1, 0, false), -128);
    CHECK_EQ(ta::requantize(-1000, 7, 3, true), 0);   // ReLU
    CHECK_EQ(ta::requantize(INT32_MIN, 0x7fffffff, 62, false), -1);   // largest magnitude product: -2^62 + 2^31 over 2^62

    std::ifstream in(argv[1]);
    CHECK(in.good());
    unsigned value, mult, shift, relu, result;
    int cases = 0;
    std::string line;
    while (std::getline(in, line)) {
        if (std::sscanf(line.c_str(), "%x %x %x %x %x", &value, &mult, &shift, &relu, &result) != 5) continue;
        const int8_t got = ta::requantize(int32_t(value), mult, shift, relu != 0);
        if (uint8_t(got) != result)
            std::fprintf(stderr, "value=%08x mult=%08x shift=%u relu=%u: model %02x, Python %02x\n",
                         value, mult, shift, relu, unsigned(uint8_t(got)), result);
        CHECK_EQ(unsigned(uint8_t(got)), result);
        cases++;
    }
    std::printf("requantization cases from %s: %d\n", argv[1], cases);
    CHECK(cases > 1000);
    return check::finish("test_requant");
}
