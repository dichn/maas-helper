# maas-helper

Enable or disable **Models-as-a-Service (MaaS)** on Red Hat OpenShift AI with one command.

MaaS puts your models behind a single gateway. Users get an **API key** tied to a **subscription**, and the subscription sets their **token quota**:

```
client --API key--> maas-default-gateway --> Authorino (checks key) + Limitador (token quota) --> vLLM model
```

| Object | What it does |
| :--- | :--- |
| `MaaSModelRef` | Publishes a model (LLMInferenceService) to MaaS |
| `MaaSAuthPolicy` | Says who may call the model (users or groups) |
| `MaaSSubscription` | Sets the token limit for those users; API keys are bound to one |
| API key | Minted with your OpenShift token at `/maas-api/v1/api-keys`, then used to call models |

## Prerequisites

- `oc login` as cluster-admin
- OpenShift AI with a `DSCInitialization` and a `DataScienceCluster`. The default DSC from the operator page is fine; maas-helper turns on what MaaS needs.
- CLI tools: `oc` 4.17+ (for `oc wait --for=create`), `make`, `envsubst`, `curl`, `jq`, `openssl`
- The following operators, installed from OperatorHub. **maas-helper does not install them.**

| Operator | Why MaaS needs it |
| :--- | :--- |
| Red Hat OpenShift AI | Runs maas-api and maas-controller, and owns the DataScienceCluster switch |
| Red Hat Connectivity Link | Kuadrant, which applies auth and rate-limit policies to the gateway |
| Authorino | Validates API keys and tokens |
| Limitador | Enforces token quotas per subscription |

MaaS also needs Istio (the gateway runs on it). OpenShift 4.19+ deploys Istio itself; on older versions install Red Hat OpenShift Service Mesh 3.

`make check` verifies all of the above.

## Quick start

```bash
make enable-maas                       # turn MaaS on (idempotent, safe to re-run)
make status                            # show what is running
make deploy-sample-model test-maas     # optional: publish Qwen3-0.6B (CPU) and run an end-to-end test
make delete-sample-model
make disable-maas                      # turn MaaS off
```

## What `enable-maas` does

| Step | Target | Why |
| :--- | :--- | :--- |
| 1 | `check` | Checks prerequisites and finds which DSC field holds the MaaS switch for your RHOAI version |
| 2 | `setup-kuadrant` | Creates the Kuadrant CR (which deploys Authorino and Limitador) and enables Authorino TLS |
| 3 | `setup-gateway` | Creates `maas-default-gateway` at `https://maas.<apps-domain>` |
| 4 | `setup-postgres` | Creates PostgreSQL and its secrets; maas-api stores API keys there |
| 5 | `setup-dsc` | Sets `kserve` and `aigateway.modelsAsAService` (3.5+) or `kserve.modelsAsService` (3.4) to `Managed` |
| 6 | `setup-telemetry` | Turns on token usage metrics per user, group and model |
| 7 | `health` | Calls `/maas-api/health` |

`disable-maas` deletes the MaaS registrations, sets the DSC field to `Removed`, and deletes the gateway and the PostgreSQL objects maas-helper created (label `app.kubernetes.io/managed-by=maas-helper`). LLMInferenceServices are kept, and so are `kserve`/`aigateway`, which other features share. All API keys are lost: RHOAI deletes the MaaS subscriptions when MaaS is removed, which revokes their keys, so users mint new keys after a re-enable.
`disable-maas FULL=true` also deletes Kuadrant, which leaves a cluster with only the operators installed.

## Variables

| Variable | Default | Meaning |
| :--- | :--- | :--- |
| `MAAS_HOSTNAME` | `maas.<apps-domain>` | Gateway hostname |
| `CERT_NAME` | ingress default cert | TLS secret in `openshift-ingress` |
| `FULL` | `false` | `disable-maas` also removes Kuadrant |
| `YES` | empty | Set `YES=1` to skip the confirmation prompt |

## Troubleshooting

- **DSC not Ready**: components MaaS doesn't use (for example trainer without the JobSet operator) can keep the DSC not Ready. `check` only warns; MaaS needs just KServe, plus AIGateway on 3.5.
- **An operator fails to install**: `check` prints OLM's reason. A common one is `ResolutionFailed` when Authorino was installed at a different version than Connectivity Link expects; remove the separate Authorino subscription and let Connectivity Link pull in its own.
- **A wait times out**: each step stops with the `oc wait` error. Re-run `make enable-maas`; finished steps are skipped.
- **Kuadrant stuck `MissingDependency`**: Kuadrant started before Istio. `setup-kuadrant` restarts the Kuadrant operator automatically.
- **`llamastackoperator and ogx Managed`** (RHOAI 3.5): set `llamastackoperator` to `Removed` in the DSC, otherwise the MaaS CRDs never install.
- **Health says the gateway is fine but the hostname fails** (HTTP 000/503): the gateway was re-created and got a new load balancer, and your DNS still has the old one cached. Wait a few minutes or flush your DNS cache.
- **Gateway not `Programmed`**: the cluster has no LoadBalancer support (bare metal). Install MetalLB or expose the gateway through a Route.
- **HTTP codes**: `401` means the API key is missing or invalid. `403` means the key's subscription does not include the model. `429` means the token quota is used up.
