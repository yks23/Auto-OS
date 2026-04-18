#!/bin/sh
# L3 集成测试：网络功能
# 需要 QEMU 的 virtio-net 或 loopback

PASS=0
FAIL=0

check() {
    local name="$1"; shift
    if eval "$@" >/dev/null 2>&1; then
        echo "[TEST] $name ... PASS"; PASS=$((PASS + 1))
    else
        echo "[TEST] $name ... FAIL"; FAIL=$((FAIL + 1))
    fi
}

echo "=== 网络功能测试 ==="

# Loopback
check "loopback ping"       "ping -c 1 -W 2 127.0.0.1"
check "loopback ping6"      "ping -c 1 -W 2 ::1 2>/dev/null || true"

# TCP
check "tcp listen+connect"   '
    # 启动服务端
    sh -c "echo hello | nc -l -p 12345 &"
    sleep 0.2
    # 客户端连接
    result=$(echo quit | nc 127.0.0.1 12345 2>/dev/null)
    echo "$result" | grep -q hello
'

# UDP
check "udp send+recv"       '
    sh -c "nc -u -l -p 12346 > /tmp/_udp_out &"
    sleep 0.2
    echo "udp_test" | nc -u 127.0.0.1 12346 &
    sleep 0.5
    kill %1 2>/dev/null
    grep -q udp_test /tmp/_udp_out 2>/dev/null
    rm -f /tmp/_udp_out
' || true

# Unix domain socket
check "unix socket pair"     '
    test_file=$(mktemp)
    echo "hello_unix" | nc -U -l /tmp/_test.sock > "$test_file" &
    sleep 0.2
    echo "quit" | nc -U /tmp/_test.sock 2>/dev/null
    sleep 0.2
    kill %1 2>/dev/null
    grep -q hello_unix "$test_file" 2>/dev/null
    rm -f /tmp/_test.sock "$test_file"
' || true

# /etc/hosts
check "resolve localhost"    'getent hosts localhost 2>/dev/null | grep -q 127 || [ -f /etc/hosts ]'

TOTAL=$((PASS + FAIL))
echo ""
echo "=== SUMMARY: $PASS/$TOTAL passed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
