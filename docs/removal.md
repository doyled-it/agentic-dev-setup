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

The extended selectors use each plugin name from `EXTENDED_MARKETPLACE_PLUGINS` in `dependencies.env` with `@claude-plugins-official`.

After removing plugins that depend on a marketplace, remove the marketplace entry only if this setup added it and no other plugin needs it:

```bash
claude plugin marketplace remove MARKETPLACE
codex plugin marketplace remove MARKETPLACE
```

The marketplace names are `superpowers-marketplace`, `doyled-it-skills`, and `claude-plugins-official`.

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
