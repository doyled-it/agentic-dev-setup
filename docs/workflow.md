# Development workflow

<!-- diataxis: explanation -->

The workflow puts evidence before edits. An agent should know the repository state, the relevant code path, the behavior to change, and the verification command before it writes production code.

## Evidence and standards

An informal retrospective on October 21, 2026 reviewed 25 recent repository-development sessions. Planning or design was visible in 17, branch isolation in 16, subagent use in 15, pull or merge request work in 16, and an explicit review pass in 10. The source sessions are private, so these aggregate counts are context rather than independently auditable research.

The rules below combine those observed practices with standards added to close gaps. In particular, tests and verification appeared often, while preserved evidence of a failing test before implementation appeared less consistently. This workflow therefore requires an explicit failing run for behavior changes.

## Program coordination

Work spanning several issues, workers, or sessions begins by invoking `roadmap:roadmap` (or `roadmap` in a shared-skill runtime). Reuse the existing agreed canonical `roadmap.json`, its designated owner, and approved phase decisions. Agree the roadmap before dispatching workers, and start only issues whose dependencies are Done. Propose work outside the agreed scope before starting it.

Orchestrators run read-only `sync` at each program update. Workers return evidence to the designated owner, who updates and re-renders the canonical roadmap when an issue finishes. This keeps sessions working from the same plan. Single-task work still follows the development loop below.

Orchestrators follow the levels reference in the roadmap skill. Level 1 is the program orchestrator: it owns the canonical roadmap and is the session the user talks to. Each active epic has a level 2 lead, and level 3 workers run single tasks, reviews, or fix rounds under a lead. At kickoff, level 1 asks the user once for the model and effort at each level and the parallel epic cap, offering defaults. It records the answer in `roadmap.json`, and later sessions, briefs, and handoffs reuse it instead of asking again.

Only level 1 asks the user. Workers ask their lead. A lead makes routine calls inside the agreed spec and escalates consequential ones to level 1 with a recommendation: scope or dependency changes, cross-epic interfaces, user-visible behavior the spec leaves open, security or privacy, new dependencies or cost, and anything irreversible or outward-facing. A lead never opens the user's question surface itself. It denies a worker's non-essential permission prompt with a reason, or escalates an essential one with the exact command and a recommendation.

When two or more epics or streams land on one base branch, level 1 adds a merge steward. The steward queues merges in dependency order, rebases onto the current base, runs CI on the merged result, and keeps the base green. It merges only under authority level 1 has recorded. With one active epic, the role stays off.

## Choose the size of the loop

A spelling correction or a comment cleanup can use a short path. A behavior change uses the full loop. Work that changes architecture, contracts, data ownership, or several repositories needs a written design and a plan with separate verification points.

Classify the work early:

| Class | Typical work | Expected preparation |
| --- | --- | --- |
| Trivial | Typo, formatting, one safe configuration value | Inspect, edit, verify |
| Bounded | Local feature, bug fix, small refactor | Discover, short design, plan, TDD, review |
| Architectural | New service boundary, contract change, cross-repository feature | Discovery, written design, multi-repository plan, TDD, independent review |

## 1. Discover the repository state

Read the applicable `AGENTS.md` and tool-specific instruction files. Inspect the branch, working tree, remotes, recent commits, build files, and test entry points. Preserve unrelated changes.

Invoke `development-loop` before meaningful implementation, and `using-codegraph` before understanding code. Creating and syncing the index is mandatory: run `codegraph init . --yes` at each relevant repository root without asking when the index is missing, and `codegraph sync .` before querying and after pulls, branch switches, and structural changes. Then query symbols, callers, callees, tests, and likely change impact. The only exceptions are an explicit operator no-index restriction and a prohibition on all writes. CodeGraph's own "indexing is the user's decision" text is tool guidance, not an operator restriction. A source-read-only task still creates and syncs the index, and a correction with no behavior change does not need one. If the relevant files are unsupported or yield no useful graph, report the limit and read those files directly after the graph check. The current source and tests remain the authority.

End discovery with a concrete scope: the behavior that changes, the files or interfaces likely involved, the evidence still missing, and the commands that can prove the result.

## 2. Brainstorm and design

State the user-visible result and the constraints. Compare plausible approaches when the choice affects maintainability, compatibility, or rollout. Pick one design and record the important tradeoffs.

Invoke `superpowers:brainstorming` for this phase and `superpowers:writing-plans` for the next. Carry forward decisions and implementation authority the operator already supplied.

For bounded work, a short design in the session is enough. Architectural work deserves a written design, but generated design files should remain outside the product commit unless the repository treats them as durable documentation.

## 3. Write an executable plan

Break the design into tasks that can fail and pass independently. Each task should name:

- the behavior under test;
- the files or interfaces in scope;
- the failing check to write first;
- the smallest implementation step;
- the focused and broader verification commands;
- the commit boundary.

Keep the plan small enough that another agent can execute a task without rediscovering the design.

## 4. Implement with RED, GREEN, REFACTOR

For each behavior change:

1. Add one focused test.
2. Run it and confirm that it fails for the expected reason.
3. Write the smallest production change that passes it.
4. Run the focused test again.
5. Refactor while the focused and relevant full suites remain green.
6. Commit the completed task with a Conventional Commit.

The explicit RED step matters. A test written after the implementation can pass without proving that it detects the missing behavior. Save the failing and passing output as evidence in the session or pull request.

## 5. Delegate bounded work

Delegate only when a task has a narrow owner, a clear input, and a specific return format. Good uses include repository discovery, one planned implementation task, a security pass, or an independent review.

Keep dependent edits sequential. Run independent research or reviews in parallel. Give every implementation agent the same design, repository instructions, test command, and commit boundary. Review each task before accepting it into the whole change.

Use `superpowers:subagent-driven-development` with `superpowers:test-driven-development`. When the host lacks subagents or the operator requests inline execution, use `superpowers:executing-plans` and preserve the same verification and review gates.

Fit ceremony to risk. Uniform ceremony (a cold worker per task, the full suite after every task, the most capable reviewer for a rename) makes a team slower than one person working directly. Risky tasks keep a fresh worker per task and the most capable reviewer: security, credentials, data migrations, user-facing UI, and shared interfaces. The lead or controller does small or mechanical tasks itself, such as renames, one-line fixes, and same-shape edits, or batches them into one worker, with targeted tests and a review on a cheaper tier. The full check runs once per issue, before its review gate. Ceremony scales; gates do not, and every gate still passes on its own evidence.

A worker that runs a real external tool able to write state, such as an agent CLI or an installer, runs it only in a sandbox. Use one command that sets a throwaway HOME, so a failure earlier in a chain cannot run the tool against the real home. Afterwards, list files outside the sandbox that changed during the run. The lead checks any report that nothing changed against those file times before accepting it.

## 6. Review the complete change

Use fresh eyes after implementation. A useful review checks:

- behavior against the approved scope;
- correctness at error and boundary cases;
- security and privacy;
- compatibility across callers and consumers;
- test quality rather than test count;
- documentation and `AGENTS.md` updates;
- accidental files, generated plans, credentials, and private paths.

Treat review findings as hypotheses to verify. Apply fixes with the same test-first discipline when they change behavior.

Invoke `superpowers:requesting-code-review`, then `superpowers:verification-before-completion` and `superpowers:finishing-a-development-branch`. If a host names a skill differently, resolve its installed name. If it is missing, perform the phase directly and disclose the fallback.

## 7. Verify and finish

Run focused tests, the relevant full suite, lint and static checks, and any build or type check used by CI. Inspect the final diff and Git status. For indexed repositories, refresh CodeGraph before making reachability or dead-code claims.

Choose the forge CLI from the remote host. Use `gh` for GitHub and `glab` for GitLab. Push, publish, merge, or change remotes only with explicit authorization.

Report the branch, commits, checks run, and any remaining limitation. A completion claim should point to fresh command output.
