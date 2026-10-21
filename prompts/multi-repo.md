# Multi-repository prompt

Implement `[system change]` across `[hub repository]` and its related repositories.

Start from the integration or deployment hub. Read its instructions, repository state, dependency pins, configuration, and deployment wiring. Identify the sibling producer, contract, client, consumer, interface, and documentation repositories involved. Use existing CodeGraph indexes in each repository before broad code searches.

Create a seam map covering producer, contract, consumer, interface, configuration, deployment, tests, and documentation. Establish the compatibility and rollout order before editing. Give each touched repository its own feature branch, plan tasks by dependency order, and keep commits independently reviewable.

Use RED, GREEN, REFACTOR for each behavior change. Add contract checks at both sides of an interface and at least one acceptance path that crosses the changed repository boundary. Verify version or digest updates and rendered deployment configuration.

After implementation, repeat the seam map against the actual diffs. Finish from the hub and prove that the assembled system exposes the intended behavior.

Remote authority: `[state which branches may be pushed and whether reviews may be opened]`.

Return a repository-by-repository summary, branch and commit list, rollout order, verification evidence, linked reviews if authorized, and remaining compatibility risks.
