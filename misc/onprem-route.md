# MaaS without a load balancer: ClusterIP gateway + OpenShift Route

For clusters with no LoadBalancer support and no MetalLB (bare metal, on-prem, disconnected). The MaaS gateway runs as a ClusterIP Service, and the OpenShift router, which every cluster already has, forwards traffic to it.

```
client --https://maas.<apps-domain>--> OpenShift router --Route maas-gateway (passthrough)--> maas-default-gateway (ClusterIP, TLS with CERT_NAME) --> maas-api / models
```

## Usage

1. **Prerequisites**: the operators from the [README](../README.md#prerequisites) are installed, and you are logged in as cluster-admin (`oc login`). See [Running maas-helper from a bastion](#running-maas-helper-from-a-bastion) for the tools the machine needs.
2. **Check** the cluster:
   ```bash
   make check
   ```
3. **Enable** MaaS with the gateway behind a Route:
   ```bash
   make enable-maas GATEWAY_EXPOSE=route
   # custom hostname and certificate (see "Hostname and certificate" below):
   make enable-maas GATEWAY_EXPOSE=route MAAS_HOSTNAME=maas.example.corp CERT_NAME=my-maas-cert
   ```
   It ends with `health` (HTTP 200 through the Route) and prints the API URL.
4. **Verify**: `make status`, plus the TLS check under [Verify](#verify).
5. **Publish a model and test** (optional; the sample needs internet for its model download, see [air-gapped](#fully-disconnected-air-gapped-clusters)):
   ```bash
   make deploy-sample-model test-maas
   make delete-sample-model
   ```
   `test-maas` creates an API key with your OpenShift token, so log in with `oc login` (a user token), not a certificate kubeconfig.
6. **Day 2**: re-running `make enable-maas GATEWAY_EXPOSE=route` is safe (nothing changes). `make disable-maas` removes MaaS, including Route `maas-gateway`.

Only `enable-maas` needs `GATEWAY_EXPOSE=route`. `health`, `status` and `disable-maas` find Route `maas-gateway` on their own. Values other than `loadbalancer` and `route` are rejected.

## What changes compared with the default

| | `GATEWAY_EXPOSE=loadbalancer` (default) | `GATEWAY_EXPOSE=route` |
| :--- | :--- | :--- |
| Gateway Service | `LoadBalancer` (cloud LB or MetalLB IP) | `ClusterIP`, set through the `service:` key of ConfigMap `maas-gateway-options` (`yaml/platform/gateway-options.yaml.tmpl`) |
| Gateway address | Load balancer IP or hostname | `maas-default-gateway-<class>.openshift-ingress.svc.cluster.local` (still `Programmed`) |
| Exposure | The load balancer | Route `maas-gateway` in `openshift-ingress`, `tls: passthrough`, port `https` |
| DNS | A record -> load balancer (on clouds OpenShift creates it: `DNSRecord` in `openshift-ingress`) | None for `maas.<apps-domain>`: the `*.apps` wildcard already points at the router |
| TLS | Gateway terminates with `CERT_NAME` | Same. Passthrough means the router doesn't touch TLS. |
| `health` step 1 | Calls the gateway's address | Calls the router (`routerCanonicalHostname` of the Route) |

## Hostname and certificate

- **Default `maas.<apps-domain>`**: works as is. The wildcard DNS reaches the router, and the default router certificate (`*.apps.<domain>`) covers the name.
- **Custom `MAAS_HOSTNAME`** (for example `maas.example.corp`): add a DNS record pointing it at the router (the same target as `*.apps`), and pass a `CERT_NAME` whose SAN covers it. See [onprem-metallb.md](onprem-metallb.md#2-prepare-the-certificate) for creating and checking the certificate.
- Don't use an IP address as `MAAS_HOSTNAME`: the router picks the Route by SNI, and clients send no SNI for an IP.

## Switching an existing MaaS between modes

`enable-maas` is idempotent: re-run it with the mode you want. API keys and subscriptions are kept.

```bash
make enable-maas GATEWAY_EXPOSE=route    # LoadBalancer -> ClusterIP + Route (the cloud load balancer is removed)
make enable-maas                         # back to LoadBalancer; Route maas-gateway is deleted
```

`setup-gateway` always re-applies ConfigMap `maas-gateway-options`, and Istio converts the existing Service in place. The Gateway itself is never re-applied, so changing `MAAS_HOSTNAME` or `CERT_NAME` still needs `make disable-maas` first; `setup-gateway` stops with an error when they differ from the existing gateway.

On clouds, OpenShift creates a DNS record for the gateway hostname pointing at its load balancer, and doesn't remove it when the Service becomes ClusterIP. Route mode deletes that `DNSRecord` so the hostname falls back to the `*.apps` wildcard and the router. Resolvers that cached the old load balancer address (including local proxies or VPN clients) can keep failing for a while; `health` then warns but still passes through the router.

## Verify

```bash
oc get svc maas-default-gateway-openshift-default -n openshift-ingress -o jsonpath='{.spec.type}{"\n"}'   # ClusterIP
oc get route maas-gateway -n openshift-ingress                                                          # passthrough, port https

# TLS check without -k (health and test-maas use -k)
oc get cm default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > ingress-ca.crt
curl --cacert ingress-ca.crt https://maas.<apps-domain>/maas-api/health     # 200
```

## Running maas-helper from a bastion

maas-helper is just `make` and shell scripts calling `oc`, so it runs from any machine, including a bastion, that has:

- `bash`, `make`, `oc` 4.17+, `envsubst` (package `gettext`), `curl`, `jq`, `openssl`
- a cluster-admin kubeconfig (`oc login`, or `export KUBECONFIG=<install-dir>/auth/kubeconfig`)
- network access to the API (`api.<domain>:6443`) and to the router (`*.apps.<domain>:443`). The second is only for `health` and `test-maas`; without it, enabling still works but `health` fails at the end.

```bash
git clone <this repo> && cd maas-helper
export KUBECONFIG=/path/to/kubeconfig
make check
make enable-maas GATEWAY_EXPOSE=route
```

## Fully disconnected (air-gapped) clusters

maas-helper itself doesn't download anything, but what it deploys pulls images:

| Needed by | Image or content | Notes |
| :--- | :--- | :--- |
| Operators (RHOAI, Connectivity Link, Authorino, Limitador) | Operator catalogs | Install from a mirrored catalog (oc-mirror) |
| Istio (istiod) and gateway pods | `registry.redhat.io/openshift-service-mesh/istio-pilot-rhel9` and `istio-proxyv2-rhel9` (by digest) | Not in the release payload: OpenShift installs Istio itself, but these images must be in your mirror |
| `setup-postgres` | `registry.redhat.io/rhel9/postgresql-16:latest` | A tag, so the mirror needs an `ImageTagMirrorSet` (an `ImageDigestMirrorSet` only covers digests) |
| `deploy-sample-model` (optional) | `registry.redhat.io/rhaiis/vllm-cpu-rhel9@sha256:...` and the Qwen3-0.6B model from Hugging Face | Doesn't work air-gapped unless you mirror the image and serve the model from local storage |

## Gotchas

- Route mode needs the router to serve the hostname. If the default IngressController uses a route selector or sharding, make sure it admits Route `maas-gateway` (`oc get route maas-gateway -n openshift-ingress -o jsonpath='{.status.ingress}'`).
- `make disable-maas` deletes Route `maas-gateway` together with the gateway.
- `enable-maas` re-applies ConfigMap `maas-gateway-options` on every run, so manual edits to it are overwritten. Put customizations (Service annotations, pod sizing) in `yaml/platform/gateway-options.yaml.tmpl` instead.

## Tested

On OpenShift 4.22.22, RHOAI 3.5.4, Connectivity Link 1.4.3 (AWS, but with the load balancer unused), run from a workstation that was `oc login`'d like a bastion, with OVN `EgressFirewall`s denying internet to `redhat-ai-gateway-infra`, `kuadrant-system` and `models-as-a-service`:

- `make disable-maas YES=1` then `make enable-maas GATEWAY_EXPOSE=route`: exit 0, ClusterIP Service, Route admitted, `health` 200.
- Re-running `make enable-maas GATEWAY_EXPOSE=route`: everything `unchanged`.
- In-place switch to `loadbalancer` and back to `route` without `disable-maas`: Service converted both ways, Route deleted/created, stale `DNSRecord` removed, the same API key kept working throughout.
- End to end through the Route: API key, model list, chat completion, 401 without key, key revoked. TLS verified with the ingress CA (no `-k`).
