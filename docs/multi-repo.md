# Multi-repository development

A feature is incomplete when one repository produces a contract that another repository has not consumed. This workflow treats the system boundary as the unit of work while keeping each repository's change independently reviewable.

The pattern came from a private audit completed on October 21, 2026 across four integration workspaces and 14 sibling repositories. This is an informal engineering retrospective. The source repositories cannot be independently audited from this public project. This guide publishes the common topology and checks while omitting project names, hosts, and implementation details.

## Start from the hub

Open the integration, deployment, or environment repository first. Keep its related repositories as siblings so tools and agents can inspect the full system without confusing repository roots.

```text
workspace/
  system-deploy/
  backend-service/
  client-library/
  web-application/
```

Inspect the hub for service versions, environment variables, deployment order, network assumptions, and the repositories that form the running system.

## Build the seam map

Invoke `cross-repo-completeness` during design, and use `using-codegraph` in each sibling repository. Initialize missing indexes, sync existing indexes, and verify each graph's checkout before delegating exploration. Map the complete change before choosing files. Record evidence for every relevant row.

| Surface | Evidence to locate |
| --- | --- |
| Producer | Handler, service, event publisher, or schema owner |
| Contract | OpenAPI, protobuf, event schema, shared type, or serialization rule |
| Consumer | Client method, adapter, generated binding, or downstream service |
| Interface | Page, command, workflow, or operator action that exposes the behavior |
| Configuration | Environment variable, feature flag, secret name, default, or migration |
| Deployment | Image or package version, chart, manifest, compose file, or rollout order |
| Tests | Producer contract test, consumer test, and system acceptance path |
| Documentation | User, operator, API, and repository instruction updates |

Run this audit twice. The first pass defines the plan. The second pass checks the finished change against the real diff.

## Plan by dependency order

Order tasks by the contract between repositories:

1. Define or change the contract and its producer test.
2. Update generated or handwritten clients.
3. Update downstream services and interface behavior.
4. Add configuration and deployment wiring.
5. Add acceptance coverage across a real producer and consumer.
6. Update docs and durable repository instructions.

Keep each repository on its own feature branch. Use Conventional Commits and open a separate review where that repository has a separate release or ownership boundary. Link the reviews so a maintainer can see the rollout order.

## Test the actual seam

Unit tests can prove both sides in isolation while missing a field name, default, serialization format, version pin, or deployment value. Add at least one check that crosses the boundary the feature changes.

Examples include:

- validate a client against the producer's checked-in contract;
- run a consumer against a real local producer;
- render deployment configuration and assert the expected version or environment value;
- exercise the user action through the interface and inspect the downstream result.

Use digests or explicit versions where the system requires repeatable builds. Record compatibility and rollout constraints near the contract or deployment source that enforces them.

## Finish from the hub

Return to the hub repository and invoke `cross-repo-completeness` in audit mode. Verify sibling branch states, contract compatibility, package or image references, configuration, deployment order, acceptance tests, and documentation.

Do not report the system change as complete because every individual repository has green unit tests. Completion requires evidence that the assembled system exposes the intended behavior.
