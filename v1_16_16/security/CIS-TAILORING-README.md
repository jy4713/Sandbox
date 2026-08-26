# CIS Level 1 assessment and tailoring - v1.16.16

The Golden Image is hardened by `.devcontainer/cis-level1-harden.sh` and is then
assessed externally with **OpenSCAP** using pinned **ComplianceAsCode** Ubuntu
24.04 CIS Level 1 content.

Important: this is independent SCAP assessment evidence. It is **not** CIS-CAT,
CIS certification, or proof that every OS benchmark control is applicable inside
a container. The final report must be reviewed and each non-pass result classified
as one of: applicable/fix-required, container-not-applicable, approved exception,
or compensating control.

If Cyber Security approves an XCCDF tailoring file, place it at:

`security/cis-tailoring.xml`

Both `assess-cis-l1.sh` and `assess-cis-l1.ps1` detect the file automatically.
Do not disable rules merely to improve a score; every change requires an approved
rationale and compensating-control reference.

For POC, `REQUIRE_CIS_PASS=false` allows the build to emit evidence even when
rules fail. Set `REQUIRE_CIS_PASS=true` only after the tailoring/exception set has
been approved and the final Golden Image passes all remaining applicable rules.
