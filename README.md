cd C:\Temp\AI_Sandbox_Admin

Remove-Item .\Dockerfile.git-test -Force -ErrorAction SilentlyContinue

$lines = @(
'FROM sandbox/devcontainer:v1',
'',
'USER root',
'',
'RUN GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/databricks/ucode.git HEAD',
'',
'RUN rm -rf /tmp/ucode-test && git init /tmp/ucode-test && GIT_TERMINAL_PROMPT=0 git -C /tmp/ucode-test fetch --depth=1 https://github.com/databricks/ucode.git 065443738fd618fc5e808e5658a4cbf082ca30f2'
)

Set-Content -Path .\Dockerfile.git-test -Value $lines -Encoding ASCII
