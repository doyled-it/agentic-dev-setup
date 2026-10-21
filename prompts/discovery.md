# Source read-only discovery prompt

Perform read-only discovery for `[task]` in `[repository or workspace]`.

1. Read every applicable `AGENTS.md`, `CLAUDE.md`, and repository-specific instruction file.
2. Inspect the current branch, working tree, remotes, recent commits, build files, and test entry points.
3. If `.codegraph/` exists at a repository root, you may refresh that generated index metadata, then use CodeGraph to locate relevant symbols, callers, callees, impact, and affected tests. Do not create an index.
4. Read the specific source and tests identified by discovery.
5. For a multi-repository workspace, start from the integration or deployment hub and identify sibling repositories and contracts.
6. Return the current behavior, relevant code path, likely change surface, risks, unanswered facts, and commands that can verify the change.

Do not edit source, configuration, or documentation files, install dependencies, create branches, or make remote changes. Refreshing an existing generated `.codegraph/` index is the only permitted write. Distinguish observed evidence from inference.
