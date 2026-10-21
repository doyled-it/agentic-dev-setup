# Source read-only discovery prompt

Perform read-only discovery for `[task]` in `[repository or workspace]`.

1. Read every applicable `AGENTS.md`, `CLAUDE.md`, and repository-specific instruction file.
2. Inspect the current branch, working tree, remotes, recent commits, build files, and test entry points.
3. Invoke `using-codegraph`. Initialize each missing repository index with `codegraph init . --yes`, or sync an existing index, then query relevant symbols, callers, callees, impact, and affected tests. Explicit operator restrictions on indexing take precedence. If CodeGraph does not support the relevant files, report that and inspect those files directly after the graph check.
4. Read the specific source and tests identified by discovery.
5. For a multi-repository workspace, invoke `cross-repo-completeness`, start from the integration or deployment hub, and identify sibling repositories and contracts.
6. Return the current behavior, relevant code path, likely change surface, risks, unanswered facts, and commands that can verify the change.

Do not edit source, configuration, or documentation files, install dependencies, create branches, or make remote changes. Creating or refreshing generated `.codegraph/` metadata is permitted. If the CodeGraph command is missing, report that dependency blocker without installing it during this source read-only task. Distinguish observed evidence from inference.
