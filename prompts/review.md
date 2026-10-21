# Independent review prompt

Review `[branch, diff, commit, or pull request]` against `[base or requirements]`. Do not edit source, configuration, or documentation files.

Read applicable repository instructions and inspect the complete diff. Invoke `using-codegraph`, initialize missing indexes or sync existing ones, then query impact, callers, callees, and affected tests for changed symbols and files. Creating or refreshing generated index metadata is permitted. Explicit operator restrictions take precedence. If CodeGraph cannot index relevant files, report that limitation and inspect them directly after the graph check.

Prioritize findings by severity. Check behavior against requirements, boundary and error cases, security, privacy, compatibility, migrations, configuration, deployment wiring, test quality, documentation, and `AGENTS.md` updates. For multi-repository work, verify the producer-to-consumer seam and rollout order.

Report only actionable findings. For each one, give the file and line, the concrete failure mode, evidence, and the smallest reasonable correction. Separate verified defects from questions or optional improvements. If no blocking findings remain, state the checks performed and residual risks.
