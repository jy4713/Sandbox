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
