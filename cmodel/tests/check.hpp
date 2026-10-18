// Minimal test helpers: CHECK counts failures and prints the first few, and
// finish() prints a summary line and returns the process exit code.
#pragma once

#include <cstdio>

namespace check {
inline int failures = 0;
inline int checks = 0;
inline void report(bool ok, const char *expr, const char *file, int line) {
    checks++;
    if (!ok && ++failures <= 20) std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", file, line, expr);
}
inline int finish(const char *name) {
    std::printf("%s %s checks=%d failures=%d\n", failures ? "TEST_FAIL" : "TEST_PASS", name, checks, failures);
    return failures ? 1 : 0;
}
}  // namespace check

#define CHECK(expr) ::check::report(static_cast<bool>(expr), #expr, __FILE__, __LINE__)
#define CHECK_EQ(a, b) ::check::report((a) == (b), #a " == " #b, __FILE__, __LINE__)
