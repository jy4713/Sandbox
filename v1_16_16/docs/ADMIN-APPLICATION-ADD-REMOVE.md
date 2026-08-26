# AI Secure Sandbox v1.16.16 - Admin Application Add / Remove Runbook

## 1. Purpose

v1.16.16 preserves the v1.16.3 explicit runtime architecture but makes Admin application onboarding/removal less repetitive. It does **not** introduce a runtime application catalog and it does **not** install applications dynamically when a Developer starts the container.

The helper edits the same source files an Admin would edit manually in v1.16.16, and generated source is still visible for security review.

## 2. What v1.16.16 adds

```text
scripts/applications/
├── add-application.ps1
├── add-application.sh
├── remove-application.ps1
├── remove-application.sh
├── validate-application.ps1
├── validate-application.sh
├── application-helper.py
└── records/
```

On Windows, the PowerShell launchers require PowerShell 7.4+ (`pwsh`). The PowerShell and shell launchers call the same Admin-side Python 3 source editor so Windows/Linux output is consistent. Python is required only on the Admin source/build workstation for these helpers; it is not a new runtime dependency inside the Developer package.

If Python 3 is not approved/available on the Admin workstation, use the manual procedure in Section 22 of this runbook instead.

## 3. Security model remains unchanged

After Apply, the source still contains explicit code such as:

```text
Dockerfile install
    -> real/<command> stash
    -> sandbox-command-wrapper
    -> run-with-ssm-secrets profile
    -> AWS SSM
    -> real executable
    -> Squid approved service
```

The helper only reduces repetitive Admin editing.

## 4. Generated source markers

Every block generated for an application is marked:

```text
# BEGIN AI-SANDBOX APP acme-ai
...
# END AI-SANDBOX APP acme-ai
```

`remove-application` removes only blocks with that exact application marker. Existing v1.16.16 built-in application code is intentionally not converted into these markers.

The helper also creates:

```text
scripts/applications/records/<name>.json
```

This record is Admin source metadata for validation/removal. It is not copied into the DevContainer and is not read at runtime.

## 5. Supported install templates

| `InstallType` | Use | Required input |
|---|---|---|
| `npm` | Node CLI | package + exact version |
| `uv` | Python CLI | package + exact version |
| `apt` | package already available in configured apt repositories | package + exact apt version |
| `archive` | binary / ZIP / TAR.GZ download | HTTPS URL + SHA-256 + format; binary path for ZIP/TAR |
| `custom` | exceptional vendor install flow | locally reviewed Dockerfile snippet |

The helper deliberately does not provide a parameter for an arbitrary remote `curl | sh` installer.

For AWS CLI-like installation flows where a ZIP contains an installer program rather than only a binary, use a reviewed `custom` snippet or the v1.16.16 manual process.

## 6. Preview is mandatory operational practice

The helper defaults to preview. It modifies files only when `-Apply` / `--apply` is supplied.

Recommended sequence:

```text
Preview
  -> review planned files and parameters
Apply
  -> review git diff
Validate
  -> package lint
POC build/test
  -> Production release
```

## 7. Add an npm CLI - PowerShell

Preview:

```powershell
.\scripts\applications\add-application.ps1 `
  -Name acme-ai `
  -Command acme `
  -InstallType npm `
  -Package '@acme/cli' `
  -Version '1.2.3' `
  -SecretEnv ACME_API_TOKEN `
  -SsmParameter acme-api-token `
  -Egress '.acme.example' `
  -ConfigDir '.config/acme'
```

Apply after review:

```powershell
.\scripts\applications\add-application.ps1 `
  -Name acme-ai `
  -Command acme `
  -InstallType npm `
  -Package '@acme/cli' `
  -Version '1.2.3' `
  -SecretEnv ACME_API_TOKEN `
  -SsmParameter acme-api-token `
  -Egress '.acme.example' `
  -ConfigDir '.config/acme' `
  -Apply
```

Only the **secret environment-variable name** and **SSM parameter name** are command-line inputs. Never pass the real token/API key to the application helper.

## 8. Equivalent shell example

```bash
./scripts/applications/add-application.sh \
  --name acme-ai \
  --command acme \
  --install-type npm \
  --package '@acme/cli' \
  --version '1.2.3' \
  --secret-env ACME_API_TOKEN \
  --ssm-parameter acme-api-token \
  --egress '.acme.example' \
  --config-dir '.config/acme'
```

Add `--apply` after reviewing preview output.

## 9. What Apply changes for a secret-backed CLI

The helper normally creates marked blocks in:

```text
.devcontainer/Dockerfile
.devcontainer/scripts/sandbox-command-wrapper.sh
.devcontainer/scripts/run-with-ssm-secrets.sh
.devcontainer/scripts/application-audit.sh
.devcontainer/scripts/verify-runtime.sh
scripts/platform/01-setup-ssm.sh
scripts/platform/01-setup-ssm.ps1
squid/whitelist.txt                 # if egress supplied
```

It also creates the Admin record JSON.

### Dockerfile

The generated blocks contain:

- pinned install;
- real executable stash;
- optional narrow writable config directory;
- Developer-facing public symlink to the Admin command wrapper;
- optional MCP helper COPY/chmod.

### Public command wrapper

The Developer uses the normal command. The generated branch resolves the real executable, permits safe local help/version operations, and sends secret-backed operations to the app's SSM profile.

### SSM runner

The helper adds:

- profile name allowlisting;
- `get_parameter <ssm-name>`;
- process-scoped `export <ENV>`;
- sanitized credential-fetch/process audit metadata;
- `run_logged` execution.

### SSM setup

The same parameter name is inserted into both Admin SSM setup scripts. The actual value is entered securely when the setup script is executed.

### Squid

Supplied `--egress` values are inserted into the allowlist as marked entries. After Apply, package lint must be used to detect domain overlaps.

## 10. uv/Python example

```powershell
.\scripts\applications\add-application.ps1 `
  -Name pytool `
  -Command pytool `
  -InstallType uv `
  -Package 'pytool' `
  -Version '4.1.0' `
  -SecretEnv PYTOOL_TOKEN `
  -SsmParameter pytool-token `
  -Egress '.pytool.example' `
  -Apply
```

The exact version is written into explicit Dockerfile source for the helper-managed app. Existing built-in v1.16.16 tools keep their original build-ARG approach.

## 11. Archive examples

### Direct binary

```powershell
.\scripts\applications\add-application.ps1 `
  -Name vendcli `
  -Command vendcli `
  -InstallType archive `
  -Url 'https://downloads.vendor.example/vendcli-2.0.0-linux-amd64' `
  -Sha256 '<APPROVED_64_HEX_SHA256>' `
  -ArchiveFormat binary `
  -SecretEnv VENDCLI_TOKEN `
  -SsmParameter vendcli-token `
  -Egress '.vendor.example' `
  -Apply
```

The generated Dockerfile downloads over HTTPS, verifies SHA-256, then installs the executable.

### ZIP

Add:

```text
-ArchiveFormat zip
-BinaryPath 'vendcli/bin/vendcli'
```

### TAR.GZ

Use:

```text
-ArchiveFormat tar.gz
-BinaryPath 'vendcli/bin/vendcli'
```

`BinaryPath` must be a safe relative extraction path.

## 12. apt example

Use `apt` only when the approved repository is already configured in the image build and an exact version is known.

```powershell
.\scripts\applications\add-application.ps1 `
  -Name sample `
  -Command sample `
  -InstallType apt `
  -Package 'sample-cli' `
  -Version '2.4.1-1' `
  -Apply
```

If a new vendor apt repository, signing key, or repository bootstrap is required, use a reviewed custom snippet or the manual runbook. Do not hide repository trust configuration inside the helper.

## 13. custom install example

Create a local reviewed file, for example:

```text
admin-snippets/acme-install.dockerfile
```

The file should contain only the Dockerfile commands required to install the approved pinned app. Then:

```powershell
.\scripts\applications\add-application.ps1 `
  -Name acme-ai `
  -Command acme `
  -InstallType custom `
  -CustomSnippet '.\admin-snippets\acme-install.dockerfile' `
  -SecretEnv ACME_API_TOKEN `
  -SsmParameter acme-api-token `
  -Egress '.acme.example' `
  -Apply
```

`custom` means the helper performs source insertion only. It does not determine whether the supplied installer is safe. Review HTTPS, version pinning, signature/checksum, repository keys, installed paths, and cleanup manually.

## 14. Add an MCP integration

For a simple MCP server launched as the application's binary plus an optional subcommand:

```powershell
.\scripts\applications\add-application.ps1 `
  -Name acme-ai `
  -Command acme `
  -InstallType npm `
  -Package '@acme/cli' `
  -Version '1.2.3' `
  -SecretEnv ACME_API_TOKEN `
  -SsmParameter acme-api-token `
  -Egress '.acme.example' `
  -Mcp `
  -McpSubcommand mcp `
  -Apply
```

The helper creates:

```text
.devcontainer/scripts/acme-ai-mcp-ssm.sh
```

and adds secret-free Claude/Gemini user-scope MCP registration pointing to:

```text
/usr/local/bin/acme-ai-mcp-ssm
```

The MCP wrapper records only lifecycle metadata (`server_start`, `server_end`, exit/duration, `stdio`). It does not log MCP request/response bodies.

If the MCP server requires complex arguments, transport flags, multiple binaries, or special environment setup, treat the generated wrapper as a starting point and manually review/edit it before release.

## 15. Validate after Apply

PowerShell:

```powershell
.\scripts\applications\validate-application.ps1 -Name acme-ai -RunLint
```

Shell:

```bash
./scripts/applications/validate-application.sh --name acme-ai --run-lint
```

Validation checks that helper-managed markers exist in the expected integration files, MCP wrapper exists when requested, markers are balanced, and optionally runs the existing package lint.

Validation is not a substitute for `git diff`. Always inspect the generated source.

## 16. Configure the actual SSM credential

After source validation, execute the normal Admin SSM setup workflow for the target environment. Enter the credential only at the secure prompt generated in `01-setup-ssm`.

Confirm:

```text
helper SsmParameter == setup script parameter == run-with-ssm-secrets get_parameter name
```

Do not put the credential in the helper record JSON.

## 17. POC acceptance after adding an app

1. Package lint passes.
2. Review source diff.
3. Build POC DevContainer/Squid images. For application-layer-only changes, v1.16.16 may use `build-sandbox.ps1 -SandboxType POC -ReuseHardenedBase`; the Admin entry point reuses the old hardened base only after validating the complete copied `.build.env`, the exact digest, and hardening labels, and automatically rebuilds the hardened base if any requirement fails.
4. Start the POC Sandbox.
5. Confirm `/usr/local/bin/<command>` resolves to the Admin wrapper.
6. Confirm `/usr/local/libexec/ai-sandbox/real/<command>` exists.
7. Confirm AWS authentication: static Access Key/Secret Key is used first when present; browser SSO is the fallback when static keys are absent.
8. Run local help/version without unnecessary secret fetch where supported.
9. Run one approved real operation.
10. Confirm app event log creation for secret-backed apps.
11. Confirm Squid access logging and destination behavior.
12. If MCP enabled, test from both Claude and Gemini.
13. Verify `mcp-events.log` and `<app>-events.log` correlation.
14. Search logs for a dummy secret and a deliberately confidential test argument/query; neither should be present in application/MCP audit logs.
15. Run image/CIS/security acceptance gates.

## 18. Production release

An app add/remove still requires a new DevContainer image. v1.16.16 does not make runtime installation dynamic.

For Production:

1. complete POC/security acceptance;
2. build the Production image;
3. publish immutable ECR digest;
4. if Squid changed, publish new Squid digest;
5. publish/update the approved-image manifest;
6. verify Developer `pull-and-start` resolves the newly approved image;
7. retain previous approved digest according to rollback policy.

## 19. Remove a helper-managed v1.16.16 app

### Preview removal

PowerShell:

```powershell
.\scripts\applications\remove-application.ps1 -Name acme-ai
```

Shell:

```bash
./scripts/applications/remove-application.sh --name acme-ai
```

The preview lists every source file that contains that application's generated marker.

Before Apply, determine whether any generated Squid domain or SSM parameter is shared with another workload.

### Apply removal

```powershell
.\scripts\applications\remove-application.ps1 -Name acme-ai -Apply
```

or:

```bash
./scripts/applications/remove-application.sh --name acme-ai --apply
```

The helper removes only exact `BEGIN/END AI-SANDBOX APP acme-ai` blocks, deletes the generated MCP launcher if one exists, and deletes the helper record.

## 20. What remove-application intentionally does not delete

The helper does **not**:

- call AWS SSM delete-parameter;
- revoke a vendor API key;
- delete a SaaS account;
- determine whether a Squid domain is shared outside helper-managed source;
- delete an old ECR image/digest;
- change the central approved manifest automatically.

Those actions have wider impact and require explicit Admin/change review.

Preferred credential-removal order:

```text
remove app from source/image
-> validate + POC
-> publish removal image
-> confirm old image retirement
-> revoke vendor credential
-> delete/disable SSM parameter
```

## 21. Removing built-in v1.16.16 applications

Claude, Gemini, Tavily, Snyk, Databricks, and any application integrated manually before v1.16.16 do not have helper records/markers.

Do not attempt to fabricate a record and run `remove-application` against them. Use:

```text
docs/ADMIN-APPLICATION-ADD-REMOVE.md
```

and reverse each explicit integration point manually.

## 22. Failure and rollback

If Apply produces an unexpected source change:

1. stop before image publication;
2. inspect `git diff`;
3. use `remove-application` for a correctly recorded helper-managed addition, or revert source control;
4. rerun package lint;
5. do not publish the image until the complete POC/security acceptance passes.

Production rollback is by approved immutable image digest/manifest, not only by source rollback.

## 23. Admin add checklist

- [ ] approval/change ticket exists
- [ ] preview reviewed
- [ ] install source is approved
- [ ] exact version is pinned
- [ ] direct download has approved SHA-256
- [ ] no unreviewed pipe-to-shell installer introduced
- [ ] only secret *names*, not secret values, supplied to helper
- [ ] generated Dockerfile block reviewed
- [ ] wrapper/SSM branch reviewed
- [ ] SSM setup names match
- [ ] audit metadata contains no content/secrets
- [ ] Squid domains are minimum required and non-overlapping
- [ ] MCP registration is secret-free
- [ ] validator passed
- [ ] package lint passed
- [ ] source diff reviewed
- [ ] POC functional test passed
- [ ] negative secret/query audit test passed
- [ ] CIS/security gates passed
- [ ] Production immutable digest/manifest updated

## 24. Admin removal checklist

- [ ] removal approved
- [ ] removal preview reviewed
- [ ] shared domains checked
- [ ] shared SSM parameters checked
- [ ] Apply removed only expected marker blocks
- [ ] validator/package lint passed after removal
- [ ] POC confirms command/MCP is absent
- [ ] Squid still works for remaining apps
- [ ] Production removal image/digest published
- [ ] old image retirement confirmed
- [ ] vendor credential revoked after retirement
- [ ] SSM parameter deleted/disabled after retirement
- [ ] documentation/change evidence updated

## 25. Manual explicit add procedure (built-in / exceptional applications)

Use this section when the application is a built-in integration, when Python helpers are unavailable, or when the install/authentication flow is too unusual for the helper templates. This preserves the explicit v1.16.3-style source model.

### 25.1 Collect approval inputs before editing

Record all of the following before changing source:

1. application name, business owner, change/security approval;
2. Developer-facing command(s);
3. official vendor installation method;
4. exact approved version (never `latest` or an open range);
5. for direct downloads, the exact HTTPS source URL and approved SHA-256;
6. runtime secret environment-variable names;
7. exact SSM parameter names under the approved Sandbox prefix;
8. required outbound FQDN/domain list;
9. MCP launch command/transport if applicable;
10. required narrow writable config/cache directories;
11. safe audit operation names and target identifiers;
12. rollback/removal dependencies, including shared domains and credentials.

### 25.2 Add build-time inputs

For version/source/hash values that must be controlled by Admin build configuration:

- add non-secret values to `.build.env.example`;
- add required-variable/format validation to `scripts/common/Load-BuildEnv.ps1` and `scripts/common/load-build-env.sh` when appropriate;
- propagate new Docker build arguments through both `scripts/poc/build-and-export.*` and `scripts/platform/02-setup-ecr.*`;
- declare/redeclare the matching `ARG` in the required Dockerfile stage(s).

Do **not** place runtime tokens/API keys/PATs in `.build.env`.

### 25.3 Install the application in `.devcontainer/Dockerfile`

Install during image build, not in `post-create.sh`. Preferred patterns are:

- npm: exact `package@version`;
- uv/Python: exact version or immutable Git commit;
- direct binary/archive: HTTPS source + SHA-256 validation before install;
- apt/deb: approved repository/package version according to supply-chain policy.

Avoid unverified remote `curl | sh`. If a vendor bootstrap installer is unavoidable, mirror/review/pin it according to the organisation's software supply-chain process.

### 25.4 Verify and stash the real executable

Before creating a public wrapper, verify that the expected executable exists and, where safe, that `--version`/`--help` works. Preserve the real vendor executable under:

```text
/usr/local/libexec/ai-sandbox/real/<command>
```

This prevents wrapper recursion and allows Admin-controlled public command paths.

### 25.5 Add only required writable directories

The runtime root filesystem is read-only. If the application needs local state, add only a narrowly scoped directory under `/home/vscode` and map/provision only that path. Do not make broad system locations writable as a workaround.

### 25.6 Add the public wrapper branch

Edit `.devcontainer/scripts/sandbox-command-wrapper.sh`.

- local inspection operations such as `--version`/`--help` may call the real binary without SSM when safe;
- secret-backed runtime operations must call `run-with-ssm-secrets --profile <app> -- <real-binary> ...`;
- never log or copy raw `$@` into audit files.

### 25.7 Add the SSM profile and runtime secret mapping

For a secret-backed app, edit `.devcontainer/scripts/run-with-ssm-secrets.sh`:

1. add the profile name to the allowlist;
2. add a profile branch;
3. call `get_parameter` only for the minimum required SSM names;
4. export the credential only for the child process;
5. emit sanitized `credential_fetch` metadata;
6. use `run_logged` with safe operation/target identifiers;
7. do not persist fetched values into workspace, `.env`, shell profiles, MCP settings, or image layers.

### 25.8 Add Admin SSM bootstrap

Update both:

```text
scripts/platform/01-setup-ssm.sh
scripts/platform/01-setup-ssm.ps1
```

Use `SecureString` for credentials. The SSM name must exactly match the runtime `get_parameter` name. Source files may contain parameter names but never real secret values.

### 25.9 Add application audit support

If `run-with-ssm-secrets` emits `application-audit --app <app>`, add the app identifier to `.devcontainer/scripts/application-audit.sh`.

Audit only sanitized metadata. Do not log prompts, queries, request/response bodies, source code, findings, credentials, remote URLs containing credentials, or complete command arguments.

Expected host log for a normal app is:

```text
C:\ProgramData\AI-Sandbox\Logs\devcontainer\<app>-events.log
```

### 25.10 Add Squid egress only when required

Edit `squid/whitelist.txt` with the minimum approved destinations. Do not add both a parent suffix such as `.example.com` and a child/apex already covered by that suffix; package lint rejects overlaps.

Any Squid allowlist change requires a new Squid image/release as well as a DevContainer release when the application set changed.

### 25.11 Add MCP when applicable

For an MCP integration:

1. create `.devcontainer/scripts/<app>-mcp-ssm.sh`;
2. resolve the real binary under `/usr/local/libexec/ai-sandbox/real/`;
3. record only MCP lifecycle metadata;
4. invoke the MCP child through `run-with-ssm-secrets` when a secret is needed;
5. COPY/chmod the wrapper in the Dockerfile;
6. register it secret-free for Claude/Gemini in `configure-mcp.sh`;
7. never place API keys/tokens in MCP configuration;
8. extend runtime verification for the wrapper and registration.

### 25.12 Extend runtime verification and package lint

At minimum verify:

- public command exists;
- public command resolves to the Admin wrapper when intended;
- real executable exists;
- runtime secret is absent from the parent environment;
- required writable path works;
- MCP wrapper/registration exists when applicable.

Add package-lint assertions for any new security invariant that must never silently regress.

### 25.13 Acceptance/release sequence

```text
source change
 -> Bash + PowerShell lint
 -> POC image build
 -> POC start
 -> browser SSO login
 -> local help/version test
 -> real approved operation
 -> application/MCP/Squid audit correlation
 -> dummy-secret/content non-leakage test
 -> CIS/image/security gates
 -> Production immutable ECR digest
 -> approved manifest update
```

An application addition always changes the DevContainer image. A Squid allowlist change also changes the Squid image.

## 26. Manual explicit removal procedure

Do not remove only the install line. First identify whether any other application shares the executable, package, SSM parameter, vendor credential, Squid domain, writable directory, MCP registration, or audit expectation.

Reverse every applicable integration point:

1. remove Dockerfile install code;
2. remove obsolete build `ARG` declarations/redeclarations;
3. remove unused `.build.env.example` values;
4. remove build-env required-variable/validation entries;
5. remove POC/Production build-argument propagation;
6. remove the `real/<command>` stash step;
7. remove the public symlink/wrapper branch;
8. remove the SSM profile allowlist/branch;
9. remove SSM bootstrap prompts from both SH and PS1;
10. remove application-audit allowlisting only if unused;
11. remove MCP wrapper/COPY/configuration when applicable;
12. remove application-only writable directories/mounts;
13. remove Squid domains only after checking they are not shared;
14. remove runtime verification/lint assertions that are no longer relevant;
15. update the current operational documentation and any external change/release evidence required by your governance process;
16. lint, rebuild and retest POC/Production.

Do **not** delete the SSM parameter or revoke the vendor credential first. Preferred order:

```text
remove app from new source/image
 -> lint + POC acceptance
 -> publish new approved image/digest
 -> verify old image/session retirement
 -> revoke vendor credential
 -> delete/disable SSM parameter
```

This keeps rollback controlled and prevents still-running approved old images from breaking unexpectedly.

## Content-logging integration rule

Do not add request/response bodies to `application-audit.sh` or `<app>-events.log`. If a future AI application requires approved content capture, implement it as a separate `*-content.log` path gated by `SANDBOX_CONTENT_LOGGING=true`, keep the default disabled, use restrictive file permissions, document the exact capture semantics, and add a lint regression that proves metadata logging remains content-free when the flag is disabled.


## v1.16.16 runtime compatibility update

- Snyk now uses `/run/ai-sandbox-snyk`, a dedicated ephemeral `exec,nosuid,nodev` tmpfs, because the Snyk CLI downloads and executes a versioned native runtime from its cache. `/tmp` and `/var/tmp` remain `noexec`.
- When `-ReuseHardenedBase`/`--reuse-hardened-base` is used, the build refreshes only the immutable `UCODE_GIT_REF` from Databricks ucode `main`; the hardened Ubuntu base is still reused.
- The DevContainer Dockerfile fails the Admin build unless the pinned ucode commit supports `--profiles`, `--use-pat`, `--skip-validate`, and `--skip-upgrade`, preventing the old interactive-browser-login regression from reaching Developers.
