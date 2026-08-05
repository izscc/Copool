#!/bin/bash
# vNext end-to-end verification script (Phase 0-9)
# Usage: scripts/vnext-verify.sh 2>&1 | tee docs/refactor/verification-report.md
set -u
APP=/Applications/icopool.app/Contents/MacOS/icopool
SUP=~/Library/Application\ Support/CodexToolsSwift
KEY=$(cat ~/.codex-tools-proxyd/api-proxy.key 2>/dev/null)
PASS=0; FAIL=0
ok()   { echo "✅ $1"; PASS=$((PASS+1)); }
bad()  { echo "❌ $1"; FAIL=$((FAIL+1)); }

echo "# Copool vNext 验证报告"
echo
echo "- 时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "- 分支: $(cd ~/Desktop/AI/Copool && git branch --show-current) @ $(cd ~/Desktop/AI/Copool && git rev-parse --short HEAD)"
echo

echo "## 1. 构建"
echo '```'
cd ~/Desktop/AI/Copool && swift build -c release 2>&1 | tail -1
echo '```'
[ -x .build/release/Copool ] && ok "Copool 二进制存在" || bad "Copool 二进制缺失"
[ -x .build/release/CopoolRouterHost ] && ok "CopoolRouterHost 二进制存在" || bad "RouterHost 缺失"

echo
echo "## 2. 部署与启动"
cp .build/release/Copool "$APP" && codesign --force --sign - /Applications/icopool.app >/dev/null 2>&1
pkill -f "$APP" 2>/dev/null; sleep 2
nohup "$APP" > /tmp/icopool.log 2>&1 & disown
for i in $(seq 1 25); do
  sleep 1
  code=$(curl -s -m 2 -o /dev/null -w "%{http_code}" http://127.0.0.1:8787/health 2>/dev/null)
  [ "$code" = "200" ] && break
done
[ "$code" = "200" ] && ok "代理启动 (health 200, ${i}s)" || bad "代理未启动 (health ${code:-无响应})"

echo
echo "## 3. 数据面回归"
# /v1/models
COUNT=$(curl -s -m 30 -H "Authorization: Bearer $KEY" http://127.0.0.1:8787/v1/models 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null)
[ "${COUNT:-0}" -ge 40 ] && ok "models 目录 $COUNT 个模型" || bad "models 目录异常: ${COUNT:-0}"

# gemini 端到端
COMP=$(curl -s -m 90 -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" http://127.0.0.1:8787/v1/responses -d '{"model":"gemini-3.6-flash-high","input":"Reply with exactly: OK","stream":false,"store":false,"max_output_tokens":100}' 2>/dev/null | grep -c '"status":"completed"')
[ "$COMP" -ge 1 ] && ok "gemini 端到端 (completed ×$COMP)" || bad "gemini 请求失败"

# Origin 拒绝 (AC-009)
ORIGIN=$(curl -s -m 5 -H "Authorization: Bearer $KEY" -H "Origin: http://evil.example.com" http://127.0.0.1:8787/health -w "|%{http_code}" 2>/dev/null)
echo "$ORIGIN" | grep -q "403" && ok "浏览器 Origin 拒绝 403 (AC-009)" || bad "Origin 未拒绝: $ORIGIN"

echo
echo "## 4. v2 Registry 与迁移 (AC-003/004/005)"
if [ -f "$SUP/provider-registry-v2.json" ]; then
  python3 -c "
import json
r = json.load(open('$SUP/provider-registry-v2.json'))
assert r['version'] == 2
text = json.dumps(r)
assert 'sk-' not in text
assert all('apiKey' not in c and 'refreshToken' not in c for c in r.get('credentials', []))
print('   version=2, instances=%d, credentials=%d, catalog=%d, secret-scan=clean' % (len(r['instances']), len(r['credentials']), len(r['catalog'])))
" && ok "v2 registry 有效且无 secret (AC-003)" || bad "v2 registry 检查失败"
  JCOUNT=$(python3 -c "import json; print(len(json.load(open('$SUP/migration-journal.json'))['entries']))")
  [ "$JCOUNT" -ge 1 ] && ok "迁移 journal $JCOUNT 条 (AC-004)" || bad "journal 为空"
else
  bad "provider-registry-v2.json 不存在"
fi

echo
echo "## 5. RouterHost (Phase 6)"
pkill -f CopoolRouterHost 2>/dev/null; sleep 1
.build/release/CopoolRouterHost > /tmp/host.log 2>&1 &
HOSTPID=$!
sleep 2
python3 -c "
import socket, os
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(os.path.expanduser('~/Library/Application Support/CodexToolsSwift/host/control.sock'))
sock.sendall(b'capabilities')
resp = sock.recv(4096).decode()
assert 'supportedPaths' in resp
print('   UDS capabilities OK')
sock.close()
" && ok "RouterHost UDS control 响应" || bad "UDS control 失败"
kill $HOSTPID 2>/dev/null
sleep 1
curl -s -m 3 http://127.0.0.1:8787/health >/dev/null 2>&1 && ok "kill host 后主代理不受影响 (崩溃隔离)" || bad "主代理受影响"

echo
echo "## 结果: $PASS 通过 / $FAIL 失败"
[ "$FAIL" -eq 0 ] && echo "✅ 全部通过" || echo "❌ 存在失败"
