#!/usr/bin/env bash
# 从 stream-json log 里提出 subagent 最终的 result.subtype=success 文本。
set -euo pipefail
log="$1"
# 每行是一个 JSON 对象；找 type=result 的最后一行
python3 -c "
import json, sys
last = None
with open('$log') as f:
    for line in f:
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get('type') == 'result' and obj.get('subtype') == 'success':
            last = obj
if last:
    print(last.get('result',''))
"
