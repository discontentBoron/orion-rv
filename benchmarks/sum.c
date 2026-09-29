typedef unsigned int uint32_t;

#define BENCH_INPUT   (*(volatile uint32_t *)0x000003E0)

int main(void)
{
    uint32_t n = BENCH_INPUT;
    uint32_t sum = 0;

    for (uint32_t i = 1; i <= n; i++)
        sum += i;

    return sum;
}