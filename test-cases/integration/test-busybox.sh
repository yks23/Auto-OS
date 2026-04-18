#!/bin/sh
# L3 集成测试：BusyBox 核心命令
# 在 Starry OS QEMU 环境中运行

PASS=0
FAIL=0

check() {
    local name="$1"
    shift
    if eval "$@" >/dev/null 2>&1; then
        echo "[TEST] $name ... PASS"
        PASS=$((PASS + 1))
    else
        echo "[TEST] $name ... FAIL"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== BusyBox 核心命令测试 ==="

# 文件系统
check "ls /"               "ls / | grep -q bin"
check "ls -la"             "ls -la /tmp"
check "mkdir + rmdir"      "mkdir -p /tmp/_test_dir && rmdir /tmp/_test_dir"
check "echo + cat"         "echo hello > /tmp/_test_f && cat /tmp/_test_f | grep -q hello && rm /tmp/_test_f"
check "cp + diff"          "cp /bin/busybox /tmp/_bb && diff /bin/busybox /tmp/_bb; rm -f /tmp/_bb"
check "ln -s + readlink"   "ln -s /bin/busybox /tmp/_link && readlink /tmp/_link | grep -q busybox; rm -f /tmp/_link"
check "touch + stat"       "touch /tmp/_ts && stat /tmp/_ts; rm -f /tmp/_ts"
check "chmod"              "touch /tmp/_ch && chmod 755 /tmp/_ch; rm -f /tmp/_ch"

# 文本处理
check "grep"               "echo hello | grep -q hello"
check "sort"               "printf 'b\na\nc\n' | sort | head -1 | grep -q a"
check "wc"                 "seq 1 10 | wc -l | grep -q 10"
check "head + tail"        "seq 1 20 | head -5 | tail -1 | grep -q 5"
check "cut"                "echo 'a:b:c' | cut -d: -f2 | grep -q b"
check "tr"                 "echo hello | tr 'h' 'H' | grep -q Hello"
check "sed"                "echo hello | sed 's/hello/world/' | grep -q world"

# 进程
check "ps"                 "ps | grep -q PID"
check "id"                 "id | grep -q uid"
check "uname -a"           "uname -a | grep -qi linux"
check "env"                "env | grep -q PATH"
check "sleep"              "sleep 0.1"

# 算术和条件
check "expr"               "[ \$(expr 1 + 1) = 2 ]"
check "test -f"            "test -f /bin/busybox"
check "test -d"            "test -d /tmp"

# 管道和重定向
check "pipe chain"         "echo test | cat | cat | grep -q test"
check "redirect append"    "echo a > /tmp/_rd && echo b >> /tmp/_rd && wc -l /tmp/_rd | grep -q 2; rm -f /tmp/_rd"

TOTAL=$((PASS + FAIL))
echo ""
echo "=== SUMMARY: $PASS/$TOTAL passed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
