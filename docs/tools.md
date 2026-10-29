# Tools and installation tiers

The setup keeps durable rules, repeatable procedures, and code intelligence in separate layers. That makes the instructions short while letting skills carry the detailed workflow.

## Persistent instructions

`AGENTS.md` is the canonical repository instruction file. Codex discovers `AGENTS.md` files by scope, and current Claude Code versions can read them as project instructions. This repository also keeps a one-line `CLAUDE.md` containing `@AGENTS.md`, which gives older or explicitly CLAUDE-oriented setups the same source without maintaining two copies. See the primary instruction-loading references for [Claude Code](https://code.claude.com/docs/en/memory) and [Codex](https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide).

The installer uses the same pattern for global guidance:

- canonical copy: `~/.config/agentic-dev-setup/AGENTS.md`;
- Claude Code managed block: `~/.claude/CLAUDE.md`;
- Codex managed block: `~/.codex/AGENTS.md`.

Existing user text outside the managed setup and CodeGraph markers stays in place. The canonical workflow replaces older CodeGraph marker blocks to avoid contradictory indexing instructions.

## Core plugin tier

The default install is the part of the setup that directly controls development work:

| Plugin | Source | Job |
| --- | --- | --- |
| `superpowers` | [obra/superpowers-marketplace](https://github.com/obra/superpowers-marketplace) | Brainstorming, planning, TDD, debugging, review, worktrees, and finishing. |
| `development-loop` | [doyled-it/claude-skills](https://github.com/doyled-it/claude-skills) | Connects discovery, design, planning, implementation, and finishing. |
| `codegraph` | [doyled-it/claude-skills](https://github.com/doyled-it/claude-skills) | Makes creating and syncing indexes mandatory, and guides symbol and impact queries. |
| `cross-repo-completeness` | [doyled-it/claude-skills](https://github.com/doyled-it/claude-skills) | Checks contracts, consumers, UI, configuration, deployment, tests, and docs across repositories. |

Each plugin is installed through the native Claude Code or Codex plugin manager. Native installation provides one update path and avoids duplicate skill names from copied directories.

## Extended plugin tier

`./install.sh --full` adds these 10 plugins from Anthropic's official marketplace to Claude Code:

```text
code-review
code-simplifier
claude-md-management
claude-security
frontend-design
plugin-dev
skill-creator
mcp-server-dev
pyright-lsp
typescript-lsp
```

Codex receives the same set except `claude-security`, which requires Claude Code's Workflow tool. Including the four core plugins, full setup installs 14 native plugins in Claude Code and 13 in Codex. The default core tier is unchanged.

The official marketplace includes both Anthropic and third-party packages. The selected plugins cover review, documentation, security, frontend work, plugin authoring, MCP development, and language intelligence. Their availability can change independently of this repository. The catalog is [dependencies.env](../dependencies.env).

Full setup removes old `context7` and thin `playwright` plugins from the selected agents. It also removes an old `claude-security` installation from Codex. Claude Security remains installed in Claude Code. Core installation does not perform this migration.

## Full runtime setup

Full setup requires Node.js 22.22.2 or newer and npm. Node.js 24 is recommended for the pinned npm packages. The npm global prefix must be writable, and its `bin` directory must already be on `PATH` and take precedence over conflicting language-server installations. The installer checks effective resolution so restarted agents use the verified binaries. It does not change shell startup files or use `sudo`.

[install-full-runtime.sh](../scripts/install-full-runtime.sh) installs these pinned npm packages automatically:

| Package | Version |
| --- | --- |
| `pyright` | 1.1.414 |
| `typescript-language-server` | 6.0.2 |
| `typescript` | 6.0.3 |
| `@playwright/mcp` | 0.0.83 |

It downloads the Chromium build matched to that Playwright MCP version. Browser automation uses the official MCP server directly under the name `agentic-playwright`, with headless Chromium and an isolated browser context. It passes `--config` to load `~/.config/agentic-dev-setup/playwright.json`. The companion `runtimes.json` records absolute executable paths and arguments for both language servers and Playwright MCP. A conflicting existing `agentic-playwright` definition is preserved and stops setup with an error.

[ensure-cli-tools.sh](../scripts/ensure-cli-tools.sh) reuses working `gh` and Python 3.9+ commands. When missing, it downloads GitHub CLI 2.102.0 and uses uv to install Python 3.12 into the configured user environment. It downloads uv 0.12.18 when needed. Helper binaries go into the npm prefix's `bin` directory; release archives have SHA256 checks before extraction. These downloads require `curl` and `tar`.

Full setup then verifies JSON-RPC initialization and shutdown for both language servers, and MCP initialization, navigation to a temporary localhost page, returned page text, and browser closure. Failures stop setup with diagnostics. The probes have deadlines and output limits and clean up their processes and localhost server. Repeat them from the checkout with:

```bash
node scripts/verify-runtimes.cjs "$HOME/.config/agentic-dev-setup/runtimes.json"
```

Successful probes print `PASS pyright`, `PASS typescript`, and `PASS playwright`. They need no account login or model requests. The installer does not perform account authentication or install OS packages. Linux browser libraries may need administrator installation if Chromium cannot launch.

Project-specific authoring toolchains and SDKs, PyYAML, jq, and `timeout` are not universal full-install dependencies. Install them when a task or tool needs them. The separate live validation runner requires jq.

## CodeGraph

[CodeGraph](https://github.com/colbymchenry/codegraph) builds a local code graph and exposes symbol, call-path, impact, and affected-test queries. The installer:

1. uses an existing `codegraph` command when present;
2. otherwise installs the pinned npm package from `dependencies.env`;
3. disables telemetry;
4. registers CodeGraph only with the agents selected by this installer;
5. leaves project discovery to the development task, without crawling unrelated repositories during bootstrap.

Use `--index PATH` to prepare indexes during installation. The installer runs `codegraph init PATH --yes` when `.codegraph/` is absent and `codegraph sync PATH` when it exists. Repeat the option for sibling repositories.

Indexing is mandatory during development. Invoke `using-codegraph`, initialize each missing task-repository index without asking, sync existing ones, and query before broad code searches. The only exceptions are an explicit no-index instruction and a prohibition on all writes. CodeGraph does not support every source type; after a graph check finds no useful symbols for unsupported files, inspect those files directly and record the limitation.

## Development environment versions

The versions in `dependencies.env` record the development workstation when this repository was created:

| Component | Development version |
| --- | --- |
| Claude Code | 2.1.306 |
| Codex | 0.163.0-alpha.11 |
| CodeGraph | 1.6.0 |

The local suite uses recording mocks. The separate [live validation runner and dated results](validation.md) document actual installations and fresh-agent tasks on these versions. They provide a tested environment rather than a compatibility guarantee. Rerun the relevant checks after changing a pin, marketplace source, plugin name, or CLI command.

## Updating the setup

Keep the dependency catalog public and free of local paths. Update tests before command syntax. Run the installer against temporary homes through `tests/install_test.sh`, then run the complete check script.

Review third-party plugin code and permissions before adding it. [Claude Code's plugin documentation](https://code.claude.com/docs/en/plugins) notes that enabled plugins can add hooks, processes, MCP servers, and context to every session, all under the user's permissions.
