typedef unsigned int uint32_t;

#define BENCH_N_PTR    (*(volatile uint32_t *)0x000003E0)
#define BENCH_SEED_PTR (*(volatile uint32_t *)0x000003E4)

#define MAT_N    8
#define A_BASE   0x00000040u
#define B_BASE   0x00000140u
#define C_BASE   0x00000240u

/*
 * Keep the matrices in data memory:
 *
 * A: 0x040 - 0x13F  (64 words)
 * B: 0x140 - 0x23F  (64 words)
 * C: 0x240 - 0x33F  (64 words)
 *
 * This stays below the benchmark control area at 0x3E0+.
 */

static void matmul(
    volatile uint32_t *A,
    volatile uint32_t *B,
    volatile uint32_t *C)
{
    for (uint32_t i = 0; i < MAT_N; i++) {

        for (uint32_t j = 0; j < MAT_N; j++) {

            uint32_t sum = 0;

            for (uint32_t k = 0; k < MAT_N; k++) {
                sum += A[i * MAT_N + k] *
                       B[k * MAT_N + j];
            }

            C[i * MAT_N + j] = sum;
        }
    }
}

int main(void)
{
    volatile uint32_t *A =
        (volatile uint32_t *)A_BASE;

    volatile uint32_t *B =
        (volatile uint32_t *)B_BASE;

    volatile uint32_t *C =
        (volatile uint32_t *)C_BASE;

    uint32_t n    = BENCH_N_PTR;
    uint32_t seed = BENCH_SEED_PTR;

    /*
     * Initialize matrices with deterministic values derived
     * from the runtime seed.
     */
    for (uint32_t i = 0; i < MAT_N * MAT_N; i++) {
        A[i] = (seed + 3u + i * 17u) & 0xFFu;
        B[i] = ((seed >> 8) + 5u + i * 13u) & 0xFFu;
        C[i] = 0;
    }

    uint32_t acc = 0;

    /*
     * Repeat the matrix multiplication to obtain enough
     * dynamic instructions for performance measurement.
     */
    for (uint32_t r = 0; r < n; r++) {

        matmul(A, B, C);

        /*
         * Small deterministic update prevents every iteration
         * from being completely identical.
         */
        uint32_t idx = r & 63u;

        A[idx] += (r + 1u) * 3u;

        acc ^= C[idx];
        acc ^= r * 0x9E3779B9u;
    }

    /*
     * Final checksum over the output matrix.
     */
    uint32_t checksum = 0;

    for (uint32_t i = 0; i < MAT_N * MAT_N; i++) {
        checksum += C[i];

        /*
         * Rotate-left by 3.
         */
        checksum =
            (checksum << 3) |
            (checksum >> 29);
    }

    return acc ^ checksum ^ C[0] ^ C[63] ^ seed;
}