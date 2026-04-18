#!/bin/sh
# L3 集成测试：Shell 脚本功能
# 验证 sh 的变量、算术、循环、管道、子进程、信号等

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

echo "=== Shell 功能测试 ==="

# 变量
check "variable assign"      'A=42 && [ "$A" = "42" ]'
check "variable export"      'export X=hello && sh -c "[ \$X = hello ]"'
check "default value"        '[ "${UNSET_VAR:-default}" = "default" ]'

# 算术
check "arithmetic $(())"     '[ $((2 + 3)) -eq 5 ]'
check "arithmetic multiply"  '[ $((6 * 7)) -eq 42 ]'

# 条件
check "if-else true"         'if true; then true; else false; fi'
check "if-else false"        'if false; then false; else true; fi'
check "test string eq"       '[ "abc" = "abc" ]'
check "test numeric"         '[ 10 -gt 5 ]'

# 循环
check "for loop"             'for i in 1 2 3; do :; done'
check "while loop"           'N=0; while [ $N -lt 3 ]; do N=$((N+1)); done; [ $N -eq 3 ]'

# 管道
check "simple pipe"          'echo hello | grep -q hello'
check "multi pipe"           'seq 1 100 | sort -n | tail -1 | grep -q 100'

# 子进程
check "subshell exit"        '(exit 0)'
check "subshell capture"     '[ "$(echo hello)" = "hello" ]'
check "backquote"            '[ `echo 42` = "42" ]'

# 重定向
check "redirect stdout"      'echo test > /tmp/_sh_test && grep -q test /tmp/_sh_test; rm -f /tmp/_sh_test'
check "redirect stderr"      'ls /nonexistent 2>/tmp/_sh_err; [ -s /tmp/_sh_err ]; rm -f /tmp/_sh_err'
check "here-string"          'cat <<EOF | grep -q hello
hello
EOF'

# 退出码
check "exit code 0"          'true; [ $? -eq 0 ]'
check "exit code nonzero"    'false; [ $? -ne 0 ]'

# 信号
check "kill -0 self"         'kill -0 $$'
check "trap"                 'trap "echo trapped" EXIT; true'

# Job control
check "background &"         'sleep 0.1 & wait $!'

TOTAL=$((PASS + FAIL))
echo ""
echo "=== SUMMARY: $PASS/$TOTAL passed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
