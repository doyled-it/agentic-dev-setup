# Implementation prompt

Implement `[task]` in `[repository]` using the full development loop.

Invoke `development-loop` before implementation. Read applicable instructions and inspect repository state before editing. Use an isolated feature or fix branch and preserve unrelated changes. Invoke `using-codegraph`. Indexing is mandatory: initialize missing indexes without asking, sync existing indexes, and query symbols and impact before editing. The only exceptions are an explicit operator no-index restriction and a prohibition on all writes; report unsupported source types and inspect them directly after checking the graph.

Before production edits, state the bounded design and write a task plan with independent verification points. For every behavior change, follow RED, GREEN, REFACTOR: add a focused test, run it to confirm the expected failure, implement the smallest passing change, then refactor while tests remain green.

Use specialist subagents for independent discovery, planned implementation tasks, or review when available. Review each delegated result before accepting it. Update `AGENTS.md` when commands, interfaces, architecture, or durable conventions change.

Run focused tests, the relevant full suite, lint, static checks, and the build or type check used by CI. Inspect the final diff for private data, generated planning files, unrelated edits, and credentials. Commit complete tasks with Conventional Commits.

Remote authority: `[state whether push or pull request creation is authorized]`.

Return the behavior delivered, files changed, commits created, verification evidence, and remaining limitations.
