typedef unsigned int uint32_t;

#define BENCH_N_PTR    (*(volatile uint32_t *)0x000003E0)
#define BENCH_SEED_PTR (*(volatile uint32_t *)0x000003E4)

/*
 * Keep the working set in data memory, away from:
 *   0x3E0 : input
 *   0x3E4 : seed
 *   0x3F0 : result
 *   0x3F4 : done
 *   0x3FC : stack
 */
#define MEM_BASE 0x00000200u

int main(void)
{
    volatile uint32_t *mem = (volatile uint32_t *)MEM_BASE;

    uint32_t n    = BENCH_N_PTR;
    uint32_t seed = BENCH_SEED_PTR;

    uint32_t acc = 0;

    /* Initialize a 16-word working set. */
    for (uint32_t k = 0; k < 16; k++) {
        mem[k] = seed ^ (0x9E3779B9u * k);
    }

    /*
     * Each iteration performs:
     *
     *   4 loads
     *   2 stores
     *   2 MULs
     *   2 DIVUs
     *   2 REMUs
     *
     * The two computation paths are deliberately separated so
     * the OoO scheduler has independent work available.
     */
    for (uint32_t i = 0; i < n; i++) {

        uint32_t idx0 = i & 15u;
        uint32_t idx1 = (i + 8u) & 15u;
        uint32_t j0   = (i + 4u) & 15u;
        uint32_t j1   = (i + 12u) & 15u;

        uint32_t x0 = mem[idx0];
        uint32_t y0 = mem[j0] | 1u;

        uint32_t x1 = mem[idx1];
        uint32_t y1 = mem[j1] | 1u;

        uint32_t p0 = x0 * (i + 3u);
        uint32_t q0 = p0 / y0;
        uint32_t r0 = p0 % y0;

        uint32_t p1 = x1 * (i + 5u);
        uint32_t q1 = p1 / y1;
        uint32_t r1 = p1 % y1;

        uint32_t w0 = q0 ^ r0 ^ (p0 >> 3);
        uint32_t w1 = q1 ^ r1 ^ (p1 >> 3);

        mem[idx0] = w0;
        mem[idx1] = w1;

        acc ^= w0;
        acc ^= w1 << 1;
        acc ^= p0;
        acc ^= p1 >> 2;
    }

    return acc;
}