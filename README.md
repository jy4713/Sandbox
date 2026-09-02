dockerfile
# 기존 (GitHub bare commit fetch — 실패)
&& uv tool install --python /usr/bin/python3 "git+https://github.com/databricks/ucode@${UCODE_GIT_REF}" \

# 변경 (clone 후 checkout → 로컬 설치)
&& git clone https://github.com/databricks/ucode /tmp/ucode-src \
&& git -C /tmp/ucode-src checkout "${UCODE_GIT_REF}" \
&& uv tool install --python /usr/bin/python3 /tmp/ucode-src \
&& rm -rf /tmp/ucode-src \
