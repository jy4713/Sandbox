# Your project files go here

This folder is bind-mounted to `/home/vscode/workspace` inside the devcontainer.
Everything else in the package root (`.devcontainer/`, `squid/`, `scripts/`,
`policies/`, `.build.env`, `.env`, etc.) is intentionally **not** visible
inside the container — the AI agent and any code it runs cannot read or
modify the sandbox's hardening configuration, Squid whitelist, or secrets
handling scripts, even though they live in the same package on the host.

Put your actual source code, git clones, and work files in this folder.
