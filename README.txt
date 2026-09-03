dockerfile
# 기존 (GitHub bare commit fetch — 실패)
&& uv tool install --python /usr/bin/python3 "git+https://github.com/databricks/ucode@${UCODE_GIT_REF}" \

# 변경 (clone 후 checkout → 로컬 설치)
&& git clone https://github.com/databricks/ucode /tmp/ucode-src \
&& git -C /tmp/ucode-src checkout "${UCODE_GIT_REF}" \
&& uv tool install --python /usr/bin/python3 /tmp/ucode-src \
&& rm -rf /tmp/ucode-src \



# 스크립트 실행 전에 이것만 실행
$scriptPath = "C:\Temp\AI_Sandbox_Admin\scripts\supply-chain\resolve-tool-artifacts.ps1"
$PSScriptRoot_sim = Split-Path $scriptPath
$Root_sim = Split-Path -Parent (Split-Path -Parent $PSScriptRoot_sim)
$EnvFile_sim = Join-Path $Root_sim '.build.env'
Write-Host "EnvFile will be: $EnvFile_sim"


# Docker 컨테이너에서 github.com 접근 테스트
docker run --rm ubuntu:24.04 bash -c "apt-get update -qq && apt-get install -y -qq curl && curl -v https://github.com" 2>&1 | tail -20


ENV GIT_TERMINAL_PROMPT=0
ENV GIT_ASKPASS=echo


# 기존
&& git clone https://github.com/databricks/ucode /tmp/ucode-src \

# 변경
&& git -c credential.helper='' clone https://github.com/databricks/ucode /tmp/ucode-src \

007c146d-3d97-467d-849f-6f4fe5a6a0f3


일단 확인하려고

네, 테스트 목적이면:

C:\Users\<username>\.aws\credentials

ini
[sandbox]
aws_access_key_id=AKIA...
aws_secret_access_key=...
aws_session_token=...

C:\Users\<username>\.aws\config

ini
[profile sandbox]
region=eu-north-1
output=json

 
timeout 20s /usr/local/libexec/ai-sandbox/real/mcp-remote \
  http://127.0.0.1:8771/databricks/sql-mcp \
  --enable-proxy \
  --transport http-only


  docker exec -u 0 ai-secure-sandbox-devcontainer-1 sh -c "install -d -m 700 -o 1000 -g 1000 /home/vscode/.mcp-auth"


  docker exec -u 1000:1000 ai-secure-sandbox-devcontainer-1 sh -c "mkdir -p /home/vscode/.mcp-auth && chmod 700 /home/vscode/.mcp-auth"




 
https://dev.azure.com/DraxTechnology/Generative%20AI%20Programme/_git/Drax.PoC.CodeAssistance/branches

feature/todo-app-scaffold




python3 - <<'PY'
import socket

try:
    s = socket.create_connection(("127.0.0.1", 8771), timeout=3)
    s.sendall(
        b"GET /healthz HTTP/1.1\r\n"
        b"Host: 127.0.0.1\r\n"
        b"Connection: close\r\n\r\n"
    )

    data = b""
    while True:
        x = s.recv(4096)
        if not x:
            break
        data += x

    print(data.decode(errors="replace"))
    s.close()

except Exception as e:
    print("FAILED:", repr(e))
PY


python3 - <<'PY'
import urllib.request
import time

url = "https://dev.azure.com/"
print("Connecting to:", url)
t = time.time()

try:
    r = urllib.request.urlopen(url, timeout=15)
    print("OK:", r.status, "elapsed:", round(time.time()-t, 2), "sec")
except Exception as e:
    print("FAILED:", repr(e), "elapsed:", round(time.time()-t, 2), "sec")
PY


git -c credential.helper= ls-remote \
'https://dev.azure.com/DraxTechnology/Generative%20AI%20Programme/_git/Drax.PoC.CodeAssistance'





python3 - <<'PY'
import os
import urllib.request

for k in [
    "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY",
    "http_proxy", "https_proxy", "no_proxy"
]:
    print(f"{k}={os.environ.get(k)}")

print("\nurllib proxies:")
print(urllib.request.getproxies())
PY

\




python3 - <<'PY'
import socket

s = socket.create_connection(("squid-proxy", 3128), timeout=5)

s.sendall(
    b"CONNECT dev.azure.com:443 HTTP/1.1\r\n"
    b"Host: dev.azure.com:443\r\n"
    b"Connection: close\r\n"
    b"\r\n"
)

data = s.recv(4096)
print(data.decode(errors="replace"))

s.close()
PY




















curl --noproxy '*' \
  -sS \
  --max-time 30 \
  -o /dev/null \
  -D - \
  -H 'Git-Protocol: version=2' \
  'http://127.0.0.1:8771/ado/dev/DraxTechnology/Generative%20AI%20Programme/_git/Drax.PoC.CodeAssistance/info/refs?service=git-upload-pacasdk'


asdfadsfasdfasdfasdJUN5KT5nffnkwdopuew6s8XZVqOWHAzoBQFIdCJKoct8TiP43IJG6UCJQQJ99CIACAAAAApH7F9AAASAZDO3ywXJUNxdlakjflaksdjflasdjkfalkj


aws ssm put-parameter \
  --name "/sandbox/ado-pat" \
  --value "NEW_PAT_VALUE" \
  --type SecureString \
  --overwrite \
  --profile sandbox \
  --region eu-west-2



 
 
