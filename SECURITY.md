# Security

This repository installs third-party plugins and can update user-level instruction files. Review `dependencies.env`, `install.sh`, and each upstream marketplace before running it on a sensitive workstation.

## Trust boundaries

- Claude Code and Codex plugins run with the user's permissions.
- Plugin hooks and MCP servers can start processes or access data available to the host agent.
- Marketplace updates can change plugin code after this repository is published.
- The installer uses the pinned npm package only when the CodeGraph command is absent, then disables its telemetry before agent registration.
- Bootstrap indexes only explicitly supplied `--index` paths. During development, the workflow initializes missing indexes in task repositories; an explicit operator restriction overrides that default.

Use `./install.sh --dry-run` to inspect intended actions. Instruction changes receive a timestamped backup and can be reverted with `./scripts/restore.sh latest`.

## Reporting a vulnerability

Open the repository's Security tab and select **Report a vulnerability**. Private vulnerability reporting is enabled as part of repository publication. If that control is unavailable, open a public issue without sensitive details and ask the maintainer to establish a private channel. Include the affected file, reproduction steps, impact, and any suggested mitigation only in the private report. Do not place credentials, private repository content, or exploit details in a public issue.

## Publication checks

`./scripts/check.sh` scans tracked and nonignored untracked repository files for a limited set of credential patterns, absolute home paths, non-public Git remotes, and prohibited planning artifacts. Ignored files are outside this repository publication scan. Run a maintained secret scanner before publishing because the local pattern check is supplemental.
