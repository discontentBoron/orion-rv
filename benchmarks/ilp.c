typedef unsigned int uint32_t;

#define BENCH_N_PTR    (*(volatile uint32_t *)0x000003E0)
#define BENCH_SEED_PTR (*(volatile uint32_t *)0x000003E4)

int main(void)
{
    uint32_t n    = BENCH_N_PTR;
    uint32_t seed = BENCH_SEED_PTR;

    uint32_t a0 = 0x11111111u;
    uint32_t a1 = 0x22222222u;
    uint32_t a2 = 0x33333333u;
    uint32_t a3 = 0x44444444u;
    uint32_t a4 = 0x55555555u;
    uint32_t a5 = 0x66666666u;
    uint32_t a6 = 0x77777777u;
    uint32_t a7 = 0x88888888u;

    for (uint32_t i = 0; i < n; i++) {

        uint32_t v = seed + i;

        a0 = (a0 + v) ^ 0xA5A5A5A5u;

        a1 = (a1 ^ (v + 0x11111111u))
           + 0x13579BDFu;

        a2 = (a2 + (v << 1)) ^ 0x3C3C3C3Cu;

        a3 = (a3 ^ (v << 2))
           + 0x2468ACE0u;

        a4 = (a4 + (v >> 1)) ^ 0x5A5A5A5Au;

        a5 = (a5 ^ (v >> 2))
           + 0x0F0F0F0Fu;

        a6 = (a6 + (v ^ 0xDEADBEEFu))
           ^ 0x55AA55AAu;

        a7 = (a7 + 0x33CC33CCu)
           ^ (v + 0xCAFEBABEu);
    }

    return a0 ^ a1 ^ a2 ^ a3 ^ a4 ^ a5 ^ a6 ^ a7;
}