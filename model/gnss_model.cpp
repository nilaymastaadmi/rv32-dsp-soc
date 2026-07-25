// GPS L1 C/A reference model: gold-code generation, signal synthesis, and correlation.
//
// This is the golden model for the correlator RTL, and it is self-validating: the
// generated codes are checked against the first-ten-chip octal values published in
// IS-GPS-200, and against the three-valued autocorrelation property that any correct
// gold code family must exhibit. If either check fails there is no point comparing RTL
// against it, so both run before any vectors are emitted.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <random>
#include <string>
#include <vector>

static constexpr int CA_LEN = 1023;

// Per-PRN G2 tap pairs, IS-GPS-200 Table 3-Ia (1-indexed register stages).
struct PrnTaps { int a, b; };
static const PrnTaps PRN_TAPS[33] = {
    {0,0},                                                        // index 0 unused
    {2,6},  {3,7},  {4,8},  {5,9},  {1,9},  {2,10}, {1,8},  {2,9},
    {3,10}, {2,3},  {3,4},  {5,6},  {6,7},  {7,8},  {8,9},  {9,10},
    {1,4},  {2,5},  {3,6},  {4,7},  {5,8},  {6,9},  {1,3},  {4,6},
    {5,7},  {6,8},  {7,9},  {8,10}, {1,6},  {2,7},  {3,8},  {4,9},
};

// Expected first 10 chips as an octal value, IS-GPS-200. Used as a conformance check
// rather than a regression baseline: these come from the specification, not from this
// implementation.
static const int EXPECTED_OCT[11] = {
    0, 01440, 01620, 01710, 01744, 01133, 01455, 01131, 01454, 01626, 01504
};

// Generate one period of the C/A code for a PRN as +1/-1 samples.
static std::vector<int8_t> ca_code(int prn) {
    int g1[11], g2[11];
    for (int i = 1; i <= 10; i++) { g1[i] = 1; g2[i] = 1; }

    const int ta = PRN_TAPS[prn].a, tb = PRN_TAPS[prn].b;
    std::vector<int8_t> out(CA_LEN);

    for (int k = 0; k < CA_LEN; k++) {
        int g1_out = g1[10];
        int g2_out = g2[ta] ^ g2[tb];
        int chip   = g1_out ^ g2_out;
        out[k] = chip ? -1 : +1;      // logical 1 maps to -1 in the BPSK sense

        int fb1 = g1[3] ^ g1[10];
        int fb2 = g2[2] ^ g2[3] ^ g2[6] ^ g2[8] ^ g2[9] ^ g2[10];
        for (int i = 10; i >= 2; i--) { g1[i] = g1[i-1]; g2[i] = g2[i-1]; }
        g1[1] = fb1; g2[1] = fb2;
    }
    return out;
}

static int first10_octal(const std::vector<int8_t> &c) {
    int v = 0;
    for (int i = 0; i < 10; i++) v = (v << 1) | (c[i] < 0 ? 1 : 0);
    return v;
}

static long correlate(const std::vector<int8_t> &a,
                      const std::vector<int8_t> &b, int shift) {
    long acc = 0;
    for (int i = 0; i < CA_LEN; i++)
        acc += a[i] * b[(i + shift) % CA_LEN];
    return acc;
}

static bool self_check() {
    bool ok = true;

    // 1) Spec conformance on the published first-ten-chip values.
    for (int prn = 1; prn <= 10; prn++) {
        int got = first10_octal(ca_code(prn));
        if (got != EXPECTED_OCT[prn]) {
            std::printf("  PRN %2d: first10 = %04o, expected %04o  MISMATCH\n",
                        prn, got, EXPECTED_OCT[prn]);
            ok = false;
        }
    }
    if (ok) std::printf("  first-ten-chip octal values match IS-GPS-200 for PRN 1-10\n");

    // 2) Autocorrelation must be 1023 at zero lag and one of {-1,63,-65} elsewhere.
    // This is the defining property of the Gold code family; a generator that produced
    // the right first ten chips but a wrong sequence would still fail here.
    auto c1 = ca_code(1);
    long peak = correlate(c1, c1, 0);
    bool three_valued = true;
    for (int s = 1; s < CA_LEN; s++) {
        long v = correlate(c1, c1, s);
        if (v != -1 && v != 63 && v != -65) { three_valued = false; break; }
    }
    std::printf("  PRN 1 autocorrelation peak = %ld (expect 1023), off-peak three-valued: %s\n",
                peak, three_valued ? "yes" : "NO");
    if (peak != CA_LEN || !three_valued) ok = false;

    // 3) Cross-correlation between different PRNs must stay far below the peak,
    // which is what makes simultaneous satellite acquisition possible at all.
    auto c2 = ca_code(2);
    long worst = 0;
    for (int s = 0; s < CA_LEN; s++) {
        long v = std::labs(correlate(c1, c2, s));
        if (v > worst) worst = v;
    }
    std::printf("  worst |cross-correlation| PRN1 vs PRN2 = %ld (%.1f dB below peak)\n",
                worst, 20.0 * std::log10(double(CA_LEN) / double(worst)));
    if (worst > 100) ok = false;

    return ok;
}

// Synthesise a noisy received signal: the PRN code at a given code phase, optionally
// with a carrier Doppler, buried in AWGN at a specified C/N0.
static std::vector<int8_t> make_signal(int prn, int code_phase, double cn0_dbhz,
                                       double amplitude, unsigned seed) {
    auto code = ca_code(prn);
    std::vector<int8_t> sig(CA_LEN);

    // 1 ms of code at 1023 chips, so 1 sample per chip here: noise bandwidth is the
    // chip rate, giving sigma from C/N0 directly.
    double snr_lin = std::pow(10.0, cn0_dbhz / 10.0) / 1.023e6;
    double sigma = amplitude / std::sqrt(2.0 * snr_lin);

    std::mt19937 rng(seed);
    std::normal_distribution<double> gauss(0.0, sigma);

    for (int i = 0; i < CA_LEN; i++) {
        double v = amplitude * code[(i + code_phase) % CA_LEN] + gauss(rng);
        int q = int(std::lround(v));
        if (q > 127) q = 127;
        if (q < -127) q = -127;
        sig[i] = int8_t(q);
    }
    return sig;
}

int main(int argc, char **argv) {
    std::printf("=== C/A code model self-check ===\n");
    if (!self_check()) {
        std::printf("SELF-CHECK FAILED\n");
        return 1;
    }
    std::printf("SELF-CHECK PASSED\n\n");

    if (argc < 2) return 0;

    // Emit vectors for the RTL testbench:
    //   <prefix>.code.hex     one chip per line, 1 = -1 chip, 0 = +1 chip
    //   <prefix>.samples.hex  one signed sample per line, 32-bit two's complement
    //   <prefix>.expected.txt reference correlation at every code phase
    std::string prefix = argv[1];
    int prn         = (argc > 2) ? std::atoi(argv[2]) : 1;
    int true_phase  = (argc > 3) ? std::atoi(argv[3]) : 511;
    double cn0      = (argc > 4) ? std::atof(argv[4]) : 45.0;

    auto code = ca_code(prn);
    auto sig  = make_signal(prn, true_phase, cn0, 24.0, 12345);

    FILE *f = std::fopen((prefix + ".code.hex").c_str(), "w");
    for (int i = 0; i < CA_LEN; i++) std::fprintf(f, "%d\n", code[i] < 0 ? 1 : 0);
    std::fclose(f);

    f = std::fopen((prefix + ".samples.hex").c_str(), "w");
    for (int i = 0; i < CA_LEN; i++)
        std::fprintf(f, "%08x\n", uint32_t(int32_t(sig[i])));
    std::fclose(f);

    // Reference: correlate the noisy signal against the clean code at every phase.
    f = std::fopen((prefix + ".expected.txt").c_str(), "w");
    long best = 0; int best_phase = -1;
    for (int p = 0; p < CA_LEN; p++) {
        long acc = 0;
        for (int i = 0; i < CA_LEN; i++) acc += sig[i] * code[(i + p) % CA_LEN];
        std::fprintf(f, "%4d %ld\n", p, acc);
        if (std::labs(acc) > std::labs(best)) { best = acc; best_phase = p; }
    }
    std::fclose(f);

    std::printf("PRN %d, true code phase %d, C/N0 %.1f dB-Hz\n", prn, true_phase, cn0);
    std::printf("model acquisition: peak %ld at phase %d -> %s\n",
                best, best_phase, (best_phase == true_phase) ? "CORRECT" : "WRONG");
    std::printf("vectors written with prefix '%s'\n", prefix.c_str());
    return 0;
}
