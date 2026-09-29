typedef unsigned int uint32_t;

#define BENCH_N_PTR    (*(volatile uint32_t *)0x000003E0)
#define BENCH_SEED_PTR (*(volatile uint32_t *)0x000003E4)

/*
 * 32-word working set.
 * This is well below the benchmark-control addresses:
 *
 *   0x3E0 : N
 *   0x3E4 : seed
 *   0x3F0 : result
 *   0x3F4 : done
 *   0x3FC : stack
 */
#define MEM_BASE 0x00000200u

static uint32_t mix_values(uint32_t x, uint32_t y, uint32_t s)
{
    uint32_t z;

    z = x ^ (y + 0x9E3779B9u);
    z += s * 0x045D9F3Bu;

    z ^= z >> 16;
    z *= 0x7FEB352Du;
    z ^= z >> 15;

    return z;
}

int main(void)
{
    volatile uint32_t *mem = (volatile uint32_t *)MEM_BASE;

    uint32_t n    = BENCH_N_PTR;
    uint32_t seed = BENCH_SEED_PTR;
    uint32_t acc  = 0;

    /* Initialize working set. */
    for (uint32_t k = 0; k < 32; k++) {
        mem[k] = seed ^ (0xA5A5A5A5u * (k + 1u));
    }

    /*
     * General mixed workload:
     *
     * - indexed loads
     * - indexed stores
     * - integer ALU operations
     * - multiplication
     * - conditional branches
     * - occasional division
     * - loop-carried dependencies
     */
    for (uint32_t i = 0; i < n; i++) {

        uint32_t idx = (i * 5u + (acc & 31u)) & 31u;
        uint32_t jdx = (i * 3u + 7u) & 31u;

        uint32_t x = mem[idx];
        uint32_t y = mem[jdx];

        uint32_t z = mix_values(x, y, seed + i);

        if (z & 0x80000000u) {
            z += x;
        } else {
            z ^= y;
        }

        /*
         * Only one iteration out of every 16 performs division,
         * so DIV is present but does not dominate the workload.
         */
        if ((i & 15u) == 0u) {
            z /= (seed | 1u);
        }

        mem[idx] = z;

        acc += z ^ x;
    }

    /* Final reduction / checksum pass. */
    uint32_t checksum = 0;

    for (uint32_t k = 0; k < 32; k++) {
        checksum += mem[k];

        /* Rotate-left by 3. */
        checksum =
            (checksum << 3) |
            (checksum >> 29);
    }

    return acc ^ checksum ^ mem[0] ^ mem[31];
}