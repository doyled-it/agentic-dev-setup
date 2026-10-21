# Prompt library

These prompts start common phases of the workflow. Replace bracketed placeholders and remove lines that do not fit the repository. Keep the scope, evidence, and completion conditions explicit.

| Prompt | Use it for |
| --- | --- |
| [discovery.md](discovery.md) | Source read-only orientation before a design or implementation. |
| [implementation.md](implementation.md) | A bounded feature or bug fix using the complete development loop. |
| [multi-repo.md](multi-repo.md) | A change that crosses contracts, services, clients, interfaces, or deployment repositories. |
| [review.md](review.md) | An independent review of a branch, diff, commit, or pull request. |
| [finish.md](finish.md) | Final verification, privacy checks, commit review, and authorized publication. |

The prompts assume the agent will read `AGENTS.md` and invoke relevant installed skills. They name the expected behavior directly so they still work when skill discovery differs between hosts.

Give the agent the result you want, the repositories in scope, constraints, and the authority it has for remote actions. Avoid pasting credentials or private data into a prompt.
