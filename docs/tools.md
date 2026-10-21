# Tools and installation tiers

The setup keeps durable rules, repeatable procedures, and code intelligence in separate layers. That makes the instructions short while letting skills carry the detailed workflow.

## Persistent instructions

`AGENTS.md` is the canonical repository instruction file. Codex discovers `AGENTS.md` files by scope, and current Claude Code versions can read them as project instructions. This repository also keeps a one-line `CLAUDE.md` containing `@AGENTS.md`, which gives older or explicitly CLAUDE-oriented setups the same source without maintaining two copies. See the primary instruction-loading references for [Claude Code](https://code.claude.com/docs/en/memory) and [Codex](https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide).

The installer uses the same pattern for global guidance:

- canonical copy: `~/.config/agentic-dev-setup/AGENTS.md`;
- Claude Code managed block: `~/.claude/CLAUDE.md`;
- Codex managed block: `~/.codex/AGENTS.md`.

Existing text outside the managed markers stays in place.

## Core plugin tier

The default install is the part of the setup that directly controls development work:

| Plugin | Source | Job |
| --- | --- | --- |
| `superpowers` | [obra/superpowers-marketplace](https://github.com/obra/superpowers-marketplace) | Brainstorming, planning, TDD, debugging, review, worktrees, and finishing. |
| `development-loop` | [doyled-it/claude-skills](https://github.com/doyled-it/claude-skills) | Connects discovery, design, planning, implementation, and finishing. |
| `codegraph` | [doyled-it/claude-skills](https://github.com/doyled-it/claude-skills) | Tells agents when and how to use an existing CodeGraph index. |
| `cross-repo-completeness` | [doyled-it/claude-skills](https://github.com/doyled-it/claude-skills) | Checks contracts, consumers, UI, configuration, deployment, tests, and docs across repositories. |

Each plugin is installed through the native Claude Code or Codex plugin manager. Native installation provides one update path and avoids duplicate skill names from copied directories.

## Extended plugin tier

`./install.sh --full` adds the selected extended set from Anthropic's official marketplace:

```text
code-review
code-simplifier
claude-md-management
claude-security
frontend-design
context7
playwright
plugin-dev
skill-creator
mcp-server-dev
pyright-lsp
typescript-lsp
```

These selected plugins come from Anthropic's official marketplace, which includes both Anthropic and third-party packages. They cover specialist review, documentation maintenance, security, frontend work, browser automation, plugin authoring, MCP development, and language intelligence. Their names and availability may change independently of this repository. OpenAI documents its compatible [marketplace commands and package format](https://developers.openai.com/plugins/build/plugins).

## CodeGraph

[CodeGraph](https://github.com/colbymchenry/codegraph) builds a local code graph and exposes symbol, call-path, impact, and affected-test queries. The installer:

1. uses an existing `codegraph` command when present;
2. otherwise installs the pinned npm package from `dependencies.env`;
3. disables telemetry;
4. registers CodeGraph only with the agents selected by this installer;
5. leaves repository indexing to the operator.

Use `--index PATH` to opt into indexing. The installer runs `codegraph init PATH` when `.codegraph/` is absent and `codegraph sync PATH` when it exists. Repeat the option for sibling repositories.

The durable instruction is deliberately narrower: when `.codegraph/` exists, use it before broad text searches for code relationships. When no index exists, continue with normal repository tools.

## Development environment versions

The versions in `dependencies.env` record the development workstation when this repository was created:

| Component | Development version |
| --- | --- |
| Claude Code | 2.1.306 |
| Codex | 0.163.0-alpha.11 |
| CodeGraph | 1.6.0 |

The automated suite uses recording mocks, so these values are environment context rather than a live compatibility matrix. Run `./scripts/check.sh` and a dry run after changing a pin, marketplace source, plugin name, or CLI command.

## Updating the setup

Keep the dependency catalog public and free of local paths. Update tests before command syntax. Run the installer against temporary homes through `tests/install_test.sh`, then run the complete check script.

Review third-party plugin code and permissions before adding it. [Claude Code's plugin documentation](https://code.claude.com/docs/en/plugins) notes that enabled plugins can add hooks, processes, MCP servers, and context to every session, all under the user's permissions.
