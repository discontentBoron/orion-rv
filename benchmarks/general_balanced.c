typedef unsigned int uint32_t;

#define BENCH_N_PTR    (*(volatile uint32_t *)0x000003E0)
#define BENCH_SEED_PTR (*(volatile uint32_t *)0x000003E4)

#define MEM_BASE 0x00000200u

int main(void)
{
    volatile uint32_t *mem = (volatile uint32_t *)MEM_BASE;

    uint32_t n    = BENCH_N_PTR;
    uint32_t seed = BENCH_SEED_PTR;

    uint32_t acc = 0;

    /*
     * Initialize a 32-word working set.
     */
    for (uint32_t k = 0; k < 32; k++) {
        mem[k] = seed ^ (0x13579BDFu * (k + 1u));
    }

    /*
     * Balanced mixed workload:
     *
     *   - 2 loads / iteration
     *   - 1 store / iteration
     *   - several ALU operations
     *   - 1 multiply every iteration
     *   - predictable conditional branch
     *   - 1 divide every 32 iterations
     *
     * The memory access pattern is deterministic and regular.
     */
    for (uint32_t i = 0; i < n; i++) {

        uint32_t idx = (i * 3u) & 31u;
        uint32_t jdx = (i * 3u + 8u) & 31u;

        uint32_t x = mem[idx];
        uint32_t y = mem[jdx];

        uint32_t z = x + y;
        z ^= i * 0x1021u;

        /*
         * Predictable branch: exactly one out of every
         * four iterations takes this path.
         */
        if ((i & 3u) == 0u) {
            z += x * 5u;
        } else {
            z ^= y >> 2;
        }

        /*
         * Occasional division. This is intentionally sparse
         * so that DIV does not dominate the workload.
         */
        if ((i & 31u) == 0u) {
            z += (x * 17u) / (y | 1u);
        }

        /*
         * One multiply every iteration.
         */
        z *= (0x9E3779B9u ^ (i + 1u));

        mem[idx] = z;

        /*
         * Loop-carried checksum dependency.
         */
        acc += z ^ (x << 1);
    }

    /*
     * Final checksum pass.
     */
    uint32_t checksum = 0;

    for (uint32_t k = 0; k < 32; k++) {
        checksum += mem[k];

        /*
         * Rotate-left by 5.
         */
        checksum =
            (checksum << 5) |
            (checksum >> 27);
    }

    return acc ^ checksum ^ mem[0] ^ mem[31] ^ seed;
}