/* Sanity test: the patches workflow itself produces a working kernel.
 *
 * 它不验证任何 syscall 行为，只验证：能开始 main，能 puts，能 exit(0)。
 * 用来在 CI 里确认 apply-patches → build → boot 流水线没坏。
 */
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    puts("[TEST] sanity_workflow PASS");
    return 0;
}
