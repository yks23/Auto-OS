#define _GNU_SOURCE
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char linkbuf[4096];
    ssize_t n = readlink("/proc/self/exe", linkbuf, sizeof linkbuf - 1);
    if (n < 0) {
        perror("readlink");
        printf("[TEST] proc_self_exe FAIL: readlink /proc/self/exe\n");
        return 1;
    }
    linkbuf[n] = '\0';

    char argv_resolved[PATH_MAX];
    char link_resolved[PATH_MAX];
    const char *a = argv[0];
    const char *b = linkbuf;

    if (realpath(argv[0], argv_resolved)) {
        a = argv_resolved;
    }
    if (realpath(linkbuf, link_resolved)) {
        b = link_resolved;
    }

    if (strcmp(a, b) != 0) {
        printf("[TEST] proc_self_exe FAIL: mismatch '%s' vs '%s'\n", a, b);
        return 1;
    }

    printf("[TEST] proc_self_exe PASS\n");
    return 0;
    (void)argc;
}
