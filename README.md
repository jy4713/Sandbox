지금은 Docker 문제가 아니라, Dockerfile.git-test 파일 자체가 생성되지 않았습니다. 스크린샷의 핵심은:

Get-Content : Cannot find path
'C:\Temp\AI_Sandbox_Admin\Dockerfile.git-test'
because it does not exist.

입니다.

이번에는 $lines, here-string 같은 PowerShell 문법을 전부 빼고 한 줄씩 파일에 직접 쓰겠습니다. PowerShell 5.1에서도 확실하게 됩니다.

아래를 한 줄씩 순서대로 실행해 주세요.

cd C:\Temp\AI_Sandbox_Admin
$df = "C:\Temp\AI_Sandbox_Admin\Dockerfile.git-test"
Remove-Item $df -Force -ErrorAction SilentlyContinue

첫 줄 생성:

'FROM ai-sandbox-hardened-base:poc-24.04-20260902' | Out-File -FilePath $df -Encoding ascii

그 다음:

'USER root' | Out-File -FilePath $df -Append -Encoding ascii
'RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates' | Out-File -FilePath $df -Append -Encoding ascii
'RUN GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/databricks/ucode.git HEAD' | Out-File -FilePath $df -Append -Encoding ascii

마지막:

'RUN rm -rf /tmp/ucode-test && git init /tmp/ucode-test && GIT_TERMINAL_PROMPT=0 git -C /tmp/ucode-test fetch --depth=1 https://github.com/databricks/ucode.git 065443738fd618fc5e808e5658a4cbf082ca30f2' | Out-File -FilePath $df -Append -Encoding ascii

이제 정말 만들어졌는지:

Test-Path $df

반드시:

True

가 나와야 합니다.

그 다음:

Get-Content $df

정확히 다음 5줄이면 됩니다.

FROM ai-sandbox-hardened-base:poc-24.04-20260902
USER root
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates
RUN GIT_TERMINAL_PROMPT=0 git ls-remote https://github.com/databricks/ucode.git HEAD
RUN rm -rf /tmp/ucode-test && git init /tmp/ucode-test && GIT_TERMINAL_PROMPT=0 git -C /tmp/ucode-test fetch --depth=1 https://github.com/databricks/ucode.git 065443738fd618fc5e808e5658a4cbf082ca30f2

그 다음에만 build:

docker build --no-cache --progress=plain -f $df C:\Temp\AI_Sandbox_Admin

이번 방식은 array도 없고 @'도 없고 줄연결 \도 없어서 지금까지 발생했던 PowerShell 복사/파싱 문제를 전부 피합니다.

특히 build 결과에서 아래 두 부분만 보면 됩니다.

git ls-remote https://github.com/databricks/ucode.git HEAD

와

git ... fetch --depth=1 ... 065443...

여기까지 실행되면 드디어 원래의 ucode/GitHub build 실패 원인을 제대로 재현해서 확인할 수 있습니다.
