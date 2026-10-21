# Independent review prompt

Review `[branch, diff, commit, or pull request]` against `[base or requirements]`. Do not edit source, configuration, or documentation files.

Read the applicable repository instructions and inspect the complete diff. If `.codegraph/` exists, you may refresh that generated index metadata, then use impact, caller, callee, and affected-test queries for changed symbols and files. Refreshing the existing generated index is the only permitted write.

Prioritize findings by severity. Check behavior against requirements, boundary and error cases, security, privacy, compatibility, migrations, configuration, deployment wiring, test quality, documentation, and `AGENTS.md` updates. For multi-repository work, verify the producer-to-consumer seam and rollout order.

Report only actionable findings. For each one, give the file and line, the concrete failure mode, evidence, and the smallest reasonable correction. Separate verified defects from questions or optional improvements. If no blocking findings remain, state the checks performed and residual risks.
