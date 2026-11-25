# MaaS on-premise with MetalLB

On clouds, the MaaS gateway gets a cloud load balancer. On-premise (bare metal) there is no load balancer, so the gateway never gets an address, never becomes `Programmed`, and `setup-gateway` times out. With MetalLB, maas-helper works unchanged.

```
client --DNS: maas.example.corp--> MetalLB IP --> maas-default-gateway (TLS with your cert) --> maas-api / models
```

## How the gateway gets its address

`setup-gateway` applies `yaml/platform/gateway-options.yaml.tmpl` (ConfigMap `maas-gateway-options`: Service type and pod sizing) and `yaml/platform/gateway.yaml.tmpl` (Gateway `maas-default-gateway`). OpenShift's gateway controller (Istio) then creates the Deployment and the Service `maas-default-gateway-<gatewayclass>` with `type: LoadBalancer`. MetalLB gives that Service an IP from its pool.

## The hostname must match in three places

| Where | Example |
| :--- | :--- |
| The certificate's SAN | `DNS:maas.example.corp` |
| `MAAS_HOSTNAME` | `make enable-maas MAAS_HOSTNAME=maas.example.corp` |
| DNS A record | `maas.example.corp` -> MetalLB IP |

**Do not set `MAAS_HOSTNAME` to the MetalLB IP.** The API server accepts it, but clients send no SNI when they connect to an IP, so the gateway can't match the request to the listener. Certificates also cover DNS names, not IPs. Keep the IP in DNS only.

Which certificate to use:

| Hostname | Certificate | Result |
| :--- | :--- | :--- |
| Default `maas.<apps-domain>`, DNS -> MetalLB IP | Default router cert (`*.apps.<domain>`) | ✅ |
| `MAAS_HOSTNAME=maas.example.corp` with `CERT_NAME=test-maas-cert` | Your cert, SAN includes `maas.example.corp` | ✅ |
| `MAAS_HOSTNAME=maas.example.corp` without `CERT_NAME` | Falls back to `*.apps.<domain>` | ❌ name mismatch |

The default router cert is usually issued by `ingress-operator@...` (self-signed), so clients need the OpenShift ingress CA even when the name matches.

## Steps

### 1. Check MetalLB

Installing the operator is not enough; it needs an address pool and an advertisement.

```bash
oc get ipaddresspool,l2advertisement -n metallb-system
```

### 2. Prepare the certificate

`oc create secret tls` takes no hostname. The hostname lives inside `tls.crt` as a SAN.

Check an existing certificate:

```bash
openssl x509 -in tls.crt -noout -text | grep -A1 'Subject Alternative Name'
# must list DNS:maas.example.corp (or a wildcard such as DNS:*.example.corp)
```

Or create a self-signed one for testing (clients must trust `tls.crt` as a CA; use your company CA for real users):

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=maas.example.corp" \
  -addext "subjectAltName=DNS:maas.example.corp"
```

If the certificate comes from an intermediate CA, put the full chain (server cert first, then intermediates) in `tls.crt`.

Store it in `openshift-ingress` (the Gateway's namespace). The secret name is up to you:

```bash
oc create secret tls test-maas-cert -n openshift-ingress --cert=tls.crt --key=tls.key
oc get secret test-maas-cert -n openshift-ingress   # maas-helper does not check this, so check it here
```

### 3. Dry-run (optional)

Nothing is changed on the cluster.

```bash
# Every command enable-maas would run, with your values filled in
make -n enable-maas MAAS_HOSTNAME=maas.example.corp CERT_NAME=test-maas-cert

# Validate the rendered ConfigMap and Gateway on the API server (renamed so they don't touch existing ones).
# Set GATEWAY_CLASS to the class shown in the "== MaaS gateway" line of the make -n output.
export MAAS_HOSTNAME=maas.example.corp CERT_NAME=test-maas-cert GATEWAY_CLASS=openshift-default GATEWAY_SERVICE_TYPE=LoadBalancer
cat yaml/platform/gateway-options.yaml.tmpl <(echo ---) yaml/platform/gateway.yaml.tmpl \
  | envsubst '${MAAS_HOSTNAME} ${CERT_NAME} ${GATEWAY_CLASS} ${GATEWAY_SERVICE_TYPE}' \
  | sed -e 's/name: maas-default-gateway$/name: maas-dryrun/' -e 's/name: maas-gateway-options$/name: maas-dryrun-options/' \
  | oc apply --dry-run=server -f -
```

### 4. Enable MaaS

```bash
oc get gateway maas-default-gateway -n openshift-ingress   # should be NotFound, see below
make enable-maas MAAS_HOSTNAME=maas.example.corp CERT_NAME=test-maas-cert
```

### 5. Add DNS

```bash
oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.addresses[0].value}'
# should be an IP from the MetalLB pool; create A record maas.example.corp -> that IP
```

### 6. Verify the certificate

`health` and `test-maas` use `curl -k`, which skips certificate checks, so they pass even with a wrong cert. Check it yourself. `--resolve` works before DNS exists.

```bash
IP=$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.addresses[0].value}')

# Your own cert: --cacert is your CA (or tls.crt if self-signed)
curl --resolve maas.example.corp:443:$IP --cacert tls.crt https://maas.example.corp/maas-api/health

# Default router cert: use the OpenShift ingress CA
oc get cm default-ingress-cert -n openshift-config-managed -o jsonpath='{.data.ca-bundle\.crt}' > ingress-ca.crt
curl --resolve maas.<apps-domain>:443:$IP --cacert ingress-ca.crt https://maas.<apps-domain>/maas-api/health
```

`200` or `401` means the name and the chain are fine. A TLS error means the SAN doesn't match or the CA isn't trusted.

## Gotchas

- **Pinning the MetalLB IP**: add the annotation (for example `metallb.universe.tf/loadBalancerIPs`) under `service:` in `yaml/platform/gateway-options.yaml.tmpl`, not on the live ConfigMap or Service: `enable-maas` re-applies the template on every run.
- **Existing gateway**: `setup-gateway` never changes an existing gateway's hostname or certificate; it stops with an error if `MAAS_HOSTNAME` or `CERT_NAME` differ. Delete it first with `oc delete gateway maas-default-gateway -n openshift-ingress`, then re-run `make enable-maas`. MaaS finds the gateway by name, so its routes and policies attach to the new one, but MetalLB may assign a different IP: update DNS.
- **Variables aren't saved**: pass the same values to later commands, for example `make health test-maas MAAS_HOSTNAME=maas.example.corp`.
- **Missing secret**: maas-helper doesn't create or check `CERT_NAME`. If it's missing, the HTTPS listener can't load a certificate, and `setup-gateway` or `health` fails.
- **`health` runs from your machine**: it first calls the MetalLB IP directly, so that IP must be reachable from where you run `make`. Its second check goes through DNS and only warns; before you add the DNS record it reports a stale DNS cache, which you can ignore.
- **No other MaaS setting holds the hostname**: maas-api and maas-controller find the gateway by name (`GATEWAY_NAME=maas-default-gateway`), and their routes inherit the listener hostname, so `MAAS_HOSTNAME` is the only place to set it.
