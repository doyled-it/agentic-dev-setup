# Agentic Dev Setup

This repository packages the AI-assisted development workflow I use with Claude Code and Codex. It combines persistent instructions, the Superpowers development loop, CodeGraph-assisted discovery, and a cross-repository completeness check.

The setup came from an informal retrospective completed on October 21, 2026. I reviewed public repositories, private multi-repository systems, installed tools, and 25 recent sessions selected because they involved repository development. Planning or design appeared in 17 sessions, branch isolation in 16, subagent use in 15, pull or merge request work in 16, and an explicit review pass in 10. Those observations shaped the guide. The stricter sequence in `AGENTS.md`, including visible RED, GREEN, REFACTOR evidence, is the standard this repository introduces rather than a claim about every past session.

## Quick start

```bash
git clone https://github.com/doyled-it/agentic-dev-setup.git
cd agentic-dev-setup
./install.sh --dry-run
./install.sh
```

Restart active Claude Code and Codex sessions after installation.

The default install adds the core workflow. To install the full toolset and its runtimes:

```bash
./install.sh --full
```

Full setup installs 14 native plugins in Claude Code and 13 in Codex, plus the official Playwright MCP server as `agentic-playwright`. It downloads pinned language servers and matching Chromium, supplies missing GitHub CLI and Python helpers, and verifies both language servers and browser navigation automatically. Context7 is excluded. See [full setup details](docs/tools.md#extended-plugin-tier) and the additional requirements below.

## What the default installs

- A canonical global `AGENTS.md` at `~/.config/agentic-dev-setup/AGENTS.md`.
- Managed instruction blocks for Claude Code and Codex. Existing content outside the blocks stays intact.
- [Superpowers](https://github.com/obra/superpowers), installed through its native marketplace.
- My [development-loop, codegraph, and cross-repo-completeness plugins](https://github.com/doyled-it/claude-skills).
- [CodeGraph](https://github.com/colbymchenry/codegraph) configuration with telemetry disabled. Bootstrap indexes only paths supplied with `--index`; development tasks initialize missing indexes in the repositories they need to inspect.
- Codex multi-agent support when Codex is present.

Plugins are installed through each agent's plugin manager. The script does not copy or symlink plugin skills into a second location, which avoids duplicate skill discovery and keeps updates tied to the marketplace.

The global instructions explicitly invoke `development-loop`, `using-codegraph`, and `cross-repo-completeness`, plus the Superpowers phases they compose. Missing task-repository indexes are closed before code discovery. Explicit operator restrictions take precedence, and unsupported source types receive direct inspection after the graph check.

## Installer modes

| Option | Effect |
| --- | --- |
| `--full` | Add the selected official plugins, download their runtimes, register Playwright MCP, and verify language servers and browser navigation. |
| `--claude-only` | Configure Claude Code and fail if its CLI is missing. |
| `--codex-only` | Configure Codex and fail if its CLI is missing. |
| `--skip-codegraph` | Leave the CodeGraph CLI and agent registration alone. |
| `--skip-instructions` | Leave global instruction files alone. |
| `--no-multi-agent` | Do not enable the Codex multi-agent feature. |
| `--dry-run` | Print intended actions without changing the system. |
| `--index PATH` | Initialize or sync one repository after setup. Repeat for more paths. |

Examples:

```bash
./install.sh --claude-only
./install.sh --codex-only --skip-codegraph
./install.sh --index "$HOME/projects/service" --index "$HOME/projects/web"
```

Run `./install.sh --help` for the current option list.

## Backups and restore

The installer creates one timestamped transaction before changing instruction files. Repeated runs that would make no instruction changes do not create another backup.

CodeGraph registration also writes instruction files. The installer snapshots those files before registration, restores that snapshot before applying its canonical block, and removes obsolete marker-fenced CodeGraph guidance so indexing policy has one source. User content outside the setup and CodeGraph markers is preserved. `--skip-instructions` also suppresses instruction changes caused by registration.

Restore the most recent instruction state with:

```bash
./scripts/restore.sh latest
```

The restore script only reverts instruction files managed by the selected transaction. Plugins, marketplace entries, runtime downloads and configuration, Codex multi-agent support, and MCP registrations have separate [removal instructions](docs/removal.md).

## Requirements

- macOS or Linux with Bash 3.2 or newer.
- Git for cloning this repository.
- Claude Code, Codex, or both.
- `npm` when CodeGraph is absent and must be installed by the script.
- Network access to the public marketplaces and package registry during installation.

Full setup also requires Node.js 22.22.2 or newer, npm, and a writable npm global prefix whose `bin` directory is already on `PATH`. Downloads also use public release and browser hosts. Missing helper downloads require `curl` and `tar`. Existing working `gh` and Python 3.9+ are reused; otherwise the installer downloads them without `sudo`. It does not install OS packages or log into accounts. On Linux, a failed Chromium launch may require an administrator to install browser system libraries.

The development workstation used Claude Code 2.1.306, Codex 0.163.0-alpha.11, and CodeGraph 1.6.0 when this repository was created. Local automated tests use recording mocks to verify command construction, file behavior, failure handling, and rollback. A separate [live validation runner and dated results](docs/validation.md) cover native marketplace installs, indexing, repeat installation, restore, and fresh-agent tasks. Plugin and CLI interfaces can change, so rerun the relevant checks after updating dependency pins or command syntax.

## How the workflow fits together

The working loop is documented in [docs/workflow.md](docs/workflow.md). The tool choices and plugin tiers are in [docs/tools.md](docs/tools.md). The system-wide check for projects split across several repositories is in [docs/multi-repo.md](docs/multi-repo.md).

Reusable starting prompts live in [prompts/README.md](prompts/README.md). They cover read-only discovery, implementation, multi-repository work, review, and finishing.

## Safety

Read [SECURITY.md](SECURITY.md) before installing third-party plugins. Plugins execute with the user's permissions. The installer backs up instruction files. `./scripts/check.sh` scans the publishable repository files for a limited set of common secret patterns, but those checks do not replace a maintained secret scanner.

Useful upstream references:

- [Claude Code instruction files](https://code.claude.com/docs/en/memory)
- [Claude Code plugins](https://code.claude.com/docs/en/plugins)
- [Codex plugin packaging and marketplaces](https://developers.openai.com/plugins/build/plugins)
- [Codex prompting and AGENTS.md](https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide)
- [Superpowers](https://github.com/obra/superpowers)
- [CodeGraph](https://github.com/colbymchenry/codegraph)

## Development

Run all local checks with:

```bash
./scripts/check.sh
```

Validate a real installation in disposable configuration, without model requests or copied credentials:

```bash
./scripts/validate-live.sh --dry-run
./scripts/validate-live.sh --full
```

Repeat only the installed language-server and browser checks from this checkout with:

```bash
node scripts/verify-runtimes.cjs "$HOME/.config/agentic-dev-setup/runtimes.json"
```

These checks use a temporary localhost page and make no model requests. The dated validation record distinguishes earlier plugin inventories from the completed full-runtime checks.

The local checks exercise the installer in temporary home directories, lint every shell script, scan tracked and nonignored untracked files with a limited public-safety pattern set, and reject generated planning documents from the publishable tree.
