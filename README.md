# azure-pipelines-agent-chart

[![Chart](https://github.com/Think-Cube/azure-pipelines-agent-chart/actions/workflows/chart.yml/badge.svg)](https://github.com/Think-Cube/azure-pipelines-agent-chart/actions/workflows/chart.yml)
[![Release](https://img.shields.io/github/v/release/Think-Cube/azure-pipelines-agent-chart)](https://github.com/Think-Cube/azure-pipelines-agent-chart/releases)
[![License](https://img.shields.io/github/license/Think-Cube/azure-pipelines-agent-chart)](LICENSE)
[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/azure-pipelines-agent-chart)](https://artifacthub.io/packages/search?repo=azure-pipelines-agent-chart)

Helm chart for self-hosted [Azure Pipelines](https://learn.microsoft.com/azure/devops/pipelines/agents/agents) agents on Kubernetes. [KEDA](https://keda.sh/) watches the agent pool and starts one agent per queued job; each agent runs that job in a fresh pod and unregisters. With an empty queue, nothing runs.

The agents use the [Think-Cube azure-pipelines-agent image](https://github.com/Think-Cube/docker-azure-pipelines-agent). The chart is published to GitHub Container Registry as an OCI artifact and signed with keyless Cosign. It is tested with Helm 4 and also installs with Helm 3.8 or newer.

## Prerequisites

- Kubernetes 1.28 or newer, for example AKS
- [KEDA](https://keda.sh/docs/latest/deploy/) 2.x in the cluster; the chart is tested with 2.21
- An agent pool in Azure DevOps, and a personal access token with the **Agent Pools (read, manage)** scope

## Install

```bash
helm install agents oci://ghcr.io/think-cube/charts/azure-pipelines-agent \
  --namespace azure-pipelines --create-namespace \
  --set azp.url=https://dev.azure.com/<organization> \
  --set azp.pool=<agent pool> \
  --set azp.token=<personal access token>
```

This installs the newest version. In production, pin one from [Releases](https://github.com/Think-Cube/azure-pipelines-agent-chart/releases) with `--version`, and keep the token in a Secret of your own with the key `AZP_TOKEN`, referenced through `azp.existingSecret`.

## How it works

1. **Template agent.** Azure DevOps only queues jobs for a pool that has at least one agent. After install and upgrade, a short Job registers the agent `<release>-azure-pipelines-agent-template` and leaves it offline, so the pool is never empty. It shows as offline in Azure DevOps; that is expected. Turn it off with `templateAgent.enabled: false` if the pool already has a permanent agent.
2. **Scaling.** A KEDA ScaledJob checks the pool every `scaling.pollingInterval` seconds and starts a Kubernetes Job for each queued job, up to `scaling.maxReplicaCount`.
3. **One job per agent.** Each agent starts with `--once`: it registers, runs one job in its own work directory and unregisters. No state carries over between jobs, and scaling in never stops an agent in the middle of a job.

To run only jobs an agent can handle, list its capabilities in `scaling.demands`, or keep `templateAgent.useAsParent` so KEDA matches demands against the template agent. Variables from `extraEnv` are reported to Azure DevOps as agent capabilities.

## Building container images

The agents have no Docker daemon. Microsoft notes that Docker tasks do not work on AKS, which uses containerd, and mounting a node's Docker socket would give every job root on the node. Build images with a daemonless tool such as Buildah or Kaniko, or with ACR Tasks.

## Adding tools

The image has `git`, `curl`, `jq`, `zip` and `unzip`. For other build tools, extend the image as described in its [README](https://github.com/Think-Cube/docker-azure-pipelines-agent#what-is-in-the-image) and set `image.repository` and `image.tag` to your image.

## Values

| Key | Default | Description |
|---|---|---|
| `image.repository` | `ghcr.io/think-cube/azure-pipelines-agent` | Agent image |
| `image.tag` | `1.0.0` | Image tag |
| `image.digest` | `""` | Image digest; used instead of the tag when set |
| `azp.url` | `""` | Organization URL (required) |
| `azp.pool` | `""` | Agent pool (required) |
| `azp.existingSecret` | `""` | Existing Secret with the key `AZP_TOKEN` |
| `azp.token` | `""` | Personal access token, required without an existing Secret |
| `scaling.poolID` | `""` | Numeric pool ID; KEDA looks the pool up by name when empty |
| `scaling.minReplicaCount` | `0` | Agents kept ready with an empty queue |
| `scaling.maxReplicaCount` | `10` | Most agents at the same time |
| `scaling.pollingInterval` | `30` | Seconds between queue checks |
| `scaling.strategy` | `default` | KEDA scaling strategy: `default`, `accurate` or `eager` |
| `scaling.demands` | `""` | Comma-separated demands the agents meet |
| `job.activeDeadlineSeconds` | `0` | Longest a pipeline job may run; `0` means no limit |
| `job.ttlSecondsAfterFinished` | `600` | Seconds a finished Job is kept |
| `job.terminationGracePeriodSeconds` | `120` | Seconds an agent gets to finish and unregister when stopped |
| `templateAgent.enabled` | `true` | Register the offline template agent |
| `templateAgent.name` | `""` | Template agent name; defaults to `<fullname>-template` |
| `templateAgent.useAsParent` | `true` | Match demands against the template agent |
| `workVolume.sizeLimit` | `""` | Size limit of the per-job work directory |
| `extraEnv`, `extraVolumes`, `extraVolumeMounts` | `[]` | Extra environment, volumes and mounts for the agents |
| `resources` | requests `500m`/`1Gi`, limit `4Gi` | Resources of each agent |
| `serviceAccount.create` / `annotations` | `true` / `{}` | ServiceAccount, for example for workload identity |
| `podSecurityContext` | non-root UID `10001`, `RuntimeDefault` seccomp | Pod security context |
| `securityContext` | no privilege escalation, all capabilities dropped | Container security context |
| `nodeSelector`, `tolerations`, `affinity` | empty | Scheduling |

`values.schema.json` validates every value, so a typo in a key fails the install instead of being ignored.

## Troubleshooting

```bash
kubectl --namespace azure-pipelines describe scaledjob agents-azure-pipelines-agent
kubectl --namespace azure-pipelines get jobs,pods -l app.kubernetes.io/instance=agents
kubectl --namespace keda logs deployment/keda-operator
```

- Jobs stay queued and no agent starts: check the ScaledJob events for the pool name or ID, and that the token can read the pool.
- Jobs fail with "No agent found in pool": the pool has no agent at all; enable the template agent.

## Verify the chart

```bash
cosign verify ghcr.io/think-cube/charts/azure-pipelines-agent:<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/Think-Cube/workflows/\.github/workflows/helm-chart\.yml@refs/tags/v.+$'
```

## Development

Pull requests lint the chart, validate the rendered manifests, including the KEDA resources, with kubeconform, then install KEDA and the chart into a kind cluster with each file in `ci/` and run `helm test`, which starts the agent image with the chart's security settings. Registering real agents needs an Azure DevOps organization and is not part of CI. Pushing a `vX.Y.Z` tag that matches `version` in `Chart.yaml` publishes the chart.

## License

This project is licensed under the [MIT License](LICENSE).
