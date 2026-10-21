# Validation

The setup has two kinds of checks: repeatable installer tests and fresh-agent tasks on synthetic repositories. Passing these checks establishes the behavior exercised below. It does not establish that every model, language, plugin dependency, or future marketplace update will behave the same way.

## Repeat the checks

Run the local checks without marketplace downloads:

```bash
./scripts/check.sh
```

Run a real installation with the installed Claude Code, Codex, CodeGraph, Node.js/npm, Git, and jq executables:

```bash
./scripts/validate-live.sh --dry-run
./scripts/validate-live.sh
./scripts/validate-live.sh --full --keep
```

The live runner uses a temporary home directory whose name contains spaces. It clears inherited credentials and agent configuration, sets a separate npm prefix, disables telemetry, and makes no model requests. The fresh `HOME` isolates Claude configuration without overriding `CLAUDE_CONFIG_DIR`, so native MCP registration and CodeGraph share `~/.claude.json`. It downloads public plugins through each agent's native manager. `--keep` retains synthetic configuration and logs for inspection; otherwise it removes them on exit.

The runner verifies every requested plugin is enabled, CodeGraph MCP registration exists in both agents, and Codex multi-agent support is persisted. It checks the canonical instructions, Claude import, and Codex managed block; repeats the installation without creating another instruction backup; indexes and queries a Python function; and restores all three original instruction files byte for byte. The live runner is opt-in because it uses the network. CI runs its preflight and environment-isolation guard tests.

Full validation requires Node.js 22.22.2 or newer. Full installation downloads the language servers, official Playwright MCP and matching Chromium, plus missing GitHub CLI and Python helpers. Its automatic runtime probes require both LSPs to return initialization capabilities and shut down, and Playwright MCP to navigate to a localhost page, return its unique text, and close the browser. The server starts with `--config` pointing at the generated browser JSON. Successful probes print one `PASS` line per runtime.

To repeat the functional probes against an installed full setup, run from the checkout:

```bash
node scripts/verify-runtimes.cjs "$HOME/.config/agentic-dev-setup/runtimes.json"
```

These probes have bounded runtime and output and clean up spawned processes and the temporary HTTP server. They make no external page requests or model requests. They do not validate account authentication, project-specific authoring toolchains, or SDKs. jq is a live-runner prerequisite; jq, PyYAML, and `timeout` are not universal full-install dependencies.

## Full-runtime validation

The revised full installer uses 14 native plugins in Claude Code and 13 in Codex, plus direct `agentic-playwright` MCP registration. Context7 and the thin Playwright plugin are retired; Claude Security is Claude-only because it requires the Workflow tool. These checks ran on October 21, 2026. The earlier 16-plugin observations are preserved separately.

| Check | Status |
| --- | --- |
| Fresh-home downloads and repeat installation | Passed the real full runner, including unchanged instruction backups and byte-for-byte restore. |
| Claude 14-plugin and Codex 13-plugin inventories | Passed against both native managers. |
| Retired-plugin migration on selected agents | Installed the old plugins into disposable configuration, reran full setup, and verified Context7 and the thin Playwright plugin were removed from both agents, plus Claude Security from Codex. Targeted-agent regression tests also passed. |
| Pyright and TypeScript LSP initialization and shutdown | Both actual servers passed, including a rerun after review fixes. |
| Matching Chromium and localhost navigation | The matching browser downloaded automatically and returned the synthetic page marker through the official MCP server. The probe uses a temporary working directory and short socket path. |
| Direct MCP registration in both agents and shared Claude configuration path | Passed initial installation, repeat installation, and the migration rerun. |
| Missing helper downloads | With preinstalled helpers excluded from PATH, the real bootstrap downloaded and checksum-verified GitHub CLI and uv, then installed Python 3.12.14. All three executables ran successfully. |

Live checks caught a TypeScript compatibility issue: version 7.0.2 does not ship `lib/tsserver.js`. Pinning the JavaScript-server release 6.0.3 made the actual language-server initialization pass. The Chromium checks also exposed a macOS Unix-socket path limit in the runner's long temporary directory, now handled with a short private probe directory. This Playwright version returns a snapshot file link; the probe verifies the unique page title returned by navigation instead of assuming the body appears inline.

Chromium required running the localhost probe outside the host session's outer process sandbox. No browser-sandbox bypass flag was added. Readiness remains conditional on host process permissions and Linux browser system libraries. The installer fails on an unsuccessful probe. Model-dependent workflows, including Claude Security's Workflow capability, are not established by these startup tests.

## Recorded run before full-runtime setup

Validation date: October 21, 2026. Environment: macOS with Bash 3.2, Claude Code 2.1.306, Codex 0.163.0-alpha.11, CodeGraph 1.6.0, and Superpowers 7.0.0.

The revised workflow skills were staged from `doyled-it/claude-skills` commit `74dfe19`: development-loop 1.2.0, codegraph 1.2.0, and cross-repo-completeness 1.1.0. Both agents' native managers accepted those versions. The separate public-marketplace installation checks used the versions available on the marketplace default branch. Installations follow marketplace updates, so these observations are dated rather than permanent version guarantees.

| Check | Evidence and result |
| --- | --- |
| Local setup checks | Installer, restore, static checks, Bash syntax, ShellCheck, and live-runner guard tests passed. |
| Skill repository checks | 13 policy checks, legacy-installer regressions, syntax, ShellCheck, and whitespace checks passed. |
| Real CodeGraph fixtures | Missing indexes, stale indexes, separate sibling indexes, unsupported-only source inspection, and scaffold idempotence passed. |
| Native plugin installation | Core and extended installations succeeded in disposable configuration. All 16 requested extended-install plugins were enabled in each agent. |
| Repeat installation and restore | The live `--full` runner passed: no additional backup or instruction changes on the second install; original canonical, Claude, and Codex instructions restored byte for byte. |
| Cold single-repository development | A fresh Codex session initialized the index, loaded the workflow skills, recorded failing discount regressions, corrected the formula, obtained independent reviews, and committed source and tests. All seven tests passed on an independent rerun. Generated planning files were excluded from the commit. |
| Repeat with revised skills | A second cold repository used the staged 1.2.0/1.2.0/1.1.0 skills. The session loaded the named skills, initialized and synced the index, recorded the expected RED failures, and completed the fix with independent reviews. All five tests passed on an independent rerun; its commit contained only source and tests and the working tree was clean. |
| Explicit no-index restriction | A fresh Codex session inspected the source directly, explained the restriction, and left both the repository and index state unchanged. |
| Three-repository audit | A fresh Codex session created separate indexes in the hub, service, and web repositories. It found the revision field dropped by the client and absent from the view, ran both narrow suites successfully, and demonstrated the cross-repository acceptance failure. It reported docs and runtime-wiring gaps plus inapplicable configuration slices. All three source trees stayed clean. |
| Claude fresh-agent task | Blocked by the account's weekly limit. A real model request returned the limit message. Installation checks do not establish Claude's task behavior. |

The initial single-repository task used the prior native skills with the revised global instructions; the second used the staged skill release. The audit enumerated files and read the hub seam map before indexing, so it does not demonstrate strict graph-before-every-discovery adherence. Its symbol tracing followed initialization and synchronization. Instruction files guide model behavior; these observations are not enforcement guarantees.

## Reproduce the behavioral fixtures

Use disposable repositories without existing indexes. Install the setup, restart the agent, and authorize only the operations needed by each fixture:

1. **Single repository:** give a Python discount function the incorrect formula `amount * (1 + percent / 100)`, with zero-discount and invalid-range tests. Ask for 10% of 100 to become 90 and 100% to become zero, while preserving validation and rounding. Approve that bounded design up front. Verify actual skill loads, index creation, RED then GREEN output, reviews, branch isolation, and a commit containing only intended files.
2. **Three repositories:** start in a deployment hub with sibling service and web repositories. Have the service return `state` and `revision`, while the web parser drops `revision` and the view renders only `state`. Document the intended seam in the hub. Request a source-read-only completeness audit, permitting generated indexes in all three repositories. Require source evidence for API, client, UI, configuration, deployment, tests, and docs. Producer tests alone must not establish completion.
3. **No-index exception:** ask for a source explanation while explicitly forbidding index creation, synchronization, file changes, installation, and remote operations. Verify that no index exists afterward and Git status is unchanged.

These tasks require an authenticated account and model usage. The automated runner deliberately does not copy credentials or execute them. Review command transcripts and final Git state; a final answer listing skill names does not prove the skills were loaded.

## Defects found by live validation

CodeGraph registration writes global instruction files. The installer now snapshots those files before registration so registration output cannot replace the original backup. It also restores the snapshot on failure and when `--skip-instructions` is used, and replaces obsolete fenced CodeGraph guidance with the canonical policy.

Claude imports require a backslash before each space in a path, according to the [Claude Code import documentation](https://code.claude.com/docs/en/memory#import-additional-files). The installer now escapes those spaces, with a regression check and a real installation under a home directory containing spaces. Claude's model-level import behavior remains untested while the weekly limit is active.

Independent review also found that unconditional instruction snapshots rejected symlinked dotfiles even when both instruction updates and CodeGraph registration were disabled. Snapshots now run only when registration can write instructions. A regression test verifies plugin-only installation preserves both the symlinks and their contents.

During that October 21, 2026 run, Context7 required OAuth during model startup. Installing its plugin did not complete authentication. Language-server binaries and browser downloads still needed their own functional checks; those recorded plugin inventories establish installation and enablement only. The revised full setup removes Context7 and performs automatic language-server and browser probes. The completed live results are recorded above.
