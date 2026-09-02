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


$i = 0
Get-Content .\Dockerfile.git-test | ForEach-Object {
    $i++
    "{0,2}: {1}" -f $i, $_
}



docker build --no-cache --progress=plain -f .\Dockerfile.git-test .



docker run --rm ai-sandbox-hardened-base:poc-24.04-20260902 git --version


$lines = @(
'FROM ai-sandbox-hardened-base:poc-24.04-20260902',
'USER root',
'RUN GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/databricks/ucode.git HEAD',
'RUN rm -rf /tmp/ucode-test && git init /tmp/ucode-test && GIT_TERMINAL_PROMPT=0 git -C /tmp/ucode-test fetch --depth=1 https://github.com/databricks/ucode.git 065443738fd618fc5e808e5658a4cbf082ca30f2'
)

Set-Content .\Dockerfile.git-test -Value $lines -Encoding ASCII



Get-Content .\Dockerfile.git-test

docker build --no-cache --progress=plain -f .\Dockerfile.git-test .










cd C:\Temp\AI_Sandbox_Admin

$lines = @(
'FROM ai-sandbox-hardened-base:poc-24.04-20260902',
'USER root',
'RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates',
'RUN git --version',
'RUN GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/databricks/ucode.git HEAD',
'RUN rm -rf /tmp/ucode-test && git init /tmp/ucode-test && GIT_TERMINAL_PROMPT=0 git -C /tmp/ucode-test fetch --depth=1 https://github.com/databricks/ucode.git 065443738fd618fc5e808e5658a4cbf082ca30f2'
)

Set-Content -Path .\Dockerfile.git-test -Value $lines -Encoding ASCII
