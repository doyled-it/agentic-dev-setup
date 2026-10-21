# Removing the setup

Instruction rollback and component removal are separate because plugins and CodeGraph may have existed before this installer ran.

## Restore instruction files

List the available transactions:

```bash
find "$HOME/.config/agentic-dev-setup/backups" -mindepth 1 -maxdepth 1 -type d -print
```

Restore the latest complete transaction:

```bash
./scripts/restore.sh latest
```

You can also pass one transaction's basename. The restore script rejects paths outside its backup root, incomplete transactions, symlinks, duplicate keys, and targets outside the three managed instruction files.

## Inspect before removing plugins

The installer updates existing marketplace entries and plugin installations when it finds them. Inspect current state before removing anything so you do not delete a component that predated this setup.

```bash
claude plugin marketplace list
codex plugin marketplace list
codex plugin list
```

Claude Code lists installed plugins in its plugin manager and through `claude plugin list` on versions that support that command.

## Remove installed plugins

Remove a Claude Code plugin with:

```bash
claude plugin uninstall PLUGIN@MARKETPLACE
```

Remove a Codex plugin with:

```bash
codex plugin remove PLUGIN@MARKETPLACE
```

The core selectors are:

```text
superpowers@superpowers-marketplace
development-loop@doyled-it-skills
codegraph@doyled-it-skills
cross-repo-completeness@doyled-it-skills
```

The extended selectors use each plugin name from `EXTENDED_MARKETPLACE_PLUGINS` in `dependencies.env` with `@claude-plugins-official`. Claude Security is installed only in Claude Code. Playwright uses the direct MCP registration described below.

Full setup already retires the old `context7` and `playwright` official plugins from selected agents, plus `claude-security` from Codex. Removing the current setup does not reinstall those retired plugins.

After removing plugins that depend on a marketplace, remove the marketplace entry only if this setup added it and no other plugin needs it:

```bash
claude plugin marketplace remove MARKETPLACE
codex plugin marketplace remove MARKETPLACE
```

The marketplace names are `superpowers-marketplace`, `doyled-it-skills`, and `claude-plugins-official`.

## Remove full runtimes

Instruction restore does not remove runtime configuration, packages, browsers, or helper binaries. Inspect the MCP entries and remove the registrations for agents you configured:

```bash
claude mcp get agentic-playwright
codex mcp get agentic-playwright --json
claude mcp remove --scope user agentic-playwright
codex mcp remove agentic-playwright
```

After neither agent needs them, remove the two runtime files:

```bash
rm "$HOME/.config/agentic-dev-setup/playwright.json" \
   "$HOME/.config/agentic-dev-setup/runtimes.json"
```

If no other tool uses the npm packages, remove them with:

```bash
npm uninstall -g pyright typescript-language-server typescript @playwright/mcp
```

Full setup may have replaced earlier global package versions. Instruction rollback does not restore those versions. Chromium lives in Playwright's browser cache; review other Playwright installations before deleting a cached build.

Downloaded `gh`, `uv`, and `uvx` helpers go into the npm global prefix's `bin` directory. Downloaded Python is managed by uv, with executable links in that same directory. Inspect `command -v gh uv uvx python3` and `uv python list` before removing anything. Use `uv python uninstall` for an unused managed Python version before removing uv itself. Remove only helpers this setup added; it reuses existing working commands and does not record their prior ownership.

## Remove CodeGraph registration

Remove the CodeGraph agent configuration while keeping the CLI:

```bash
codegraph uninstall --yes --target claude,codex --keep-cli
```

Use only the target installed by an agent-specific setup when appropriate:

```bash
codegraph uninstall --yes --target claude --keep-cli
codegraph uninstall --yes --target codex --keep-cli
```

CodeGraph leaves repository indexes in place. Remove an index from inside that repository with `codegraph uninit` after reviewing its prompt and impact.

## Disable Codex multi-agent support

If this setup was the reason the feature was enabled, disable it with:

```bash
codex features disable multi_agent
```

These commands are deliberately manual. The installer does not record whether a plugin, marketplace, CodeGraph registration, or feature flag existed before it ran, so an automatic uninstall could remove shared user state.
