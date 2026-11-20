BASE:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
SHELL=/bin/bash
MAAS_NS=models-as-a-service
SAMPLE_NS=maas-demo
SAMPLE_SUBSCRIPTION=qwen3-0-6b-sample
FULL=false
YES=
HEALTH_RETRIES=30
OWNED=app.kubernetes.io/managed-by=maas-helper
.NOTPARALLEL:
# Lazily evaluated (only when a target needs them)
CLUSTER_DOMAIN=$(shell oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
MAAS_HOSTNAME=maas.$(CLUSTER_DOMAIN)
# Gateway TLS: reuse the router's default certificate (secret in openshift-ingress)
CERT_NAME=$(or $(shell oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null),router-certs-default)
# OCP 4.22+ ships GatewayClass openshift-gateway-controller; older clusters get openshift-default from yaml/
GATEWAY_CLASS=$(or $(shell oc get gatewayclass openshift-gateway-controller -o name 2>/dev/null | cut -d/ -f2),openshift-default)
# Loads DSC, RHOAI_VERSION, MAAS_COMPONENT, MAAS_FIELD, MAAS_READY_COND, MAAS_API_NS, MAAS_STATE
LOAD_ENV=set -euo pipefail; ENV=$$($(BASE)/scripts/check-dsc.sh env); eval "$$ENV"

.PHONY: check
check:
	@$(BASE)/scripts/check-dsc.sh

# ---------------------------------------------------------------- enable
.PHONY: enable-maas
enable-maas: check setup-istio setup-kuadrant setup-gateway setup-postgres setup-dsc setup-telemetry health
	@echo
	@echo "🎉 MaaS is enabled"
	@echo "   API:       https://$(MAAS_HOSTNAME)"
	@if [ "$$(oc get datasciencecluster -o jsonpath='{.items[0].spec.components.dashboard.managementState}')" = "Managed" ]; then \
		echo "   Dashboard: OpenShift AI -> Models as a Service"; \
	else \
		echo "   Dashboard: off in the DSC (set spec.components.dashboard to Managed for the MaaS UI)"; \
	fi
	@echo "   Next:      make deploy-sample-model test-maas"

# Kuadrant only detects Istio when its operator starts, so Istio must be up before Kuadrant.
# On OpenShift 4.19+ the first GatewayClass for the OpenShift controller is what installs Istio.
.PHONY: setup-istio
setup-istio:
	@echo "== Istio (Gateway API provider, GatewayClass $(GATEWAY_CLASS)) =="
	@if [ "$(GATEWAY_CLASS)" = "openshift-default" ]; then oc apply -f $(BASE)/yaml/platform/gatewayclass.yaml; fi
	oc wait gatewayclass/$(GATEWAY_CLASS) --for=condition=Accepted --timeout=300s
	oc wait --for=create crd/envoyfilters.networking.istio.io crd/wasmplugins.extensions.istio.io --timeout=300s
	oc wait crd/envoyfilters.networking.istio.io crd/wasmplugins.extensions.istio.io --for=condition=Established --timeout=60s
	@echo "✅ Istio ready"

.PHONY: setup-kuadrant
setup-kuadrant: setup-istio
	@echo "== Kuadrant (Authorino + Limitador) =="
	oc apply -f $(BASE)/yaml/platform/kuadrant.yaml
	oc wait --for=create authorino/authorino -n kuadrant-system --timeout=180s
	@# MaaS talks to Authorino over TLS; trust the OpenShift service CA for outbound calls
	oc patch authorino authorino -n kuadrant-system --type=merge \
		-p '{"spec":{"listener":{"tls":{"enabled":true,"certSecretRef":{"name":"authorino-server-cert"}}}}}'
	oc wait --for=create deployment/authorino -n kuadrant-system --timeout=180s
	@# Only set env when missing, so a re-run does not restart Authorino
	@oc set env deployment/authorino -n kuadrant-system --list | grep -q '^SSL_CERT_FILE=' || \
		oc set env deployment/authorino -n kuadrant-system \
			SSL_CERT_FILE=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt \
			REQUESTS_CA_BUNDLE=/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
	@# If Kuadrant started before Istio it stays MissingDependency; a restart of its operator fixes it.
	@# Delete the pod: OLM owns the deployment and reverts 'oc rollout restart'.
	@if ! oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready --timeout=90s >/dev/null 2>&1; then \
		echo "   Kuadrant not Ready, restarting kuadrant operator"; \
		oc delete pod -n openshift-operators -l app=kuadrant,control-plane=controller-manager; \
		oc rollout status deployment/kuadrant-operator-controller-manager -n openshift-operators --timeout=180s; \
		oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready --timeout=300s; \
	fi
	@echo "✅ Kuadrant Ready"

.PHONY: setup-gateway
setup-gateway: setup-istio
	@echo "== MaaS gateway: https://$(MAAS_HOSTNAME) (class $(GATEWAY_CLASS), cert $(CERT_NAME)) =="
	@# Never re-apply an existing gateway: changing it recreates the cloud load balancer
	@if oc get gateway maas-default-gateway -n openshift-ingress >/dev/null 2>&1; then \
		echo "   maas-default-gateway already exists, leaving it as is"; \
	else \
		MAAS_HOSTNAME=$(MAAS_HOSTNAME) CERT_NAME=$(CERT_NAME) GATEWAY_CLASS=$(GATEWAY_CLASS) \
		envsubst '$${MAAS_HOSTNAME} $${CERT_NAME} $${GATEWAY_CLASS}' \
			< $(BASE)/yaml/platform/gateway.yaml.tmpl | oc apply -f -; \
	fi
	oc wait gateway/maas-default-gateway -n openshift-ingress --for=condition=Programmed --timeout=300s
	@echo "✅ Gateway Programmed"

.PHONY: setup-postgres
setup-postgres:
	@$(LOAD_ENV); \
	echo "== PostgreSQL for maas-api (namespace $$MAAS_API_NS) =="; \
	oc get namespace "$$MAAS_API_NS" >/dev/null 2>&1 || oc create namespace "$$MAAS_API_NS"; \
	if ! oc get secret postgres-creds -n "$$MAAS_API_NS" >/dev/null 2>&1; then \
		oc create secret generic postgres-creds -n "$$MAAS_API_NS" \
			--from-literal=user=maas --from-literal=database=maas \
			--from-literal=password="$$(openssl rand -hex 16)"; \
	fi; \
	if ! oc get secret maas-db-config -n "$$MAAS_API_NS" >/dev/null 2>&1; then \
		PW=$$(oc get secret postgres-creds -n "$$MAAS_API_NS" -o jsonpath='{.data.password}' | base64 -d); \
		oc create secret generic maas-db-config -n "$$MAAS_API_NS" \
			--from-literal=DB_CONNECTION_URL="postgresql://maas:$$PW@postgres.$$MAAS_API_NS.svc.cluster.local:5432/maas?sslmode=disable"; \
	fi; \
	oc label secret postgres-creds maas-db-config -n "$$MAAS_API_NS" $(OWNED) --overwrite >/dev/null; \
	DB_NS=$$MAAS_API_NS envsubst '$${DB_NS}' < $(BASE)/yaml/maas/postgres.yaml.tmpl | oc apply -f -; \
	oc rollout status deployment/postgres -n "$$MAAS_API_NS" --timeout=300s
	@echo "✅ PostgreSQL ready"

.PHONY: setup-dsc
setup-dsc:
	@$(LOAD_ENV); \
	echo "== DataScienceCluster/$$DSC: kserve + $$MAAS_COMPONENT.$$MAAS_FIELD -> Managed =="; \
	oc patch datasciencecluster "$$DSC" --type=merge -p "{\"spec\":{\"components\":{\"kserve\":{\"managementState\":\"Managed\"}}}}"; \
	oc patch datasciencecluster "$$DSC" --type=merge -p "{\"spec\":{\"components\":{\"$$MAAS_COMPONENT\":{\"managementState\":\"Managed\",\"$$MAAS_FIELD\":{\"managementState\":\"Managed\"}}}}}"; \
	echo "   Waiting for KserveReady"; \
	oc wait datasciencecluster "$$DSC" --for=condition=KserveReady --timeout=600s; \
	if [ "$$MAAS_COMPONENT" = "aigateway" ]; then \
		echo "   Waiting for AIGatewayReady (installs the MaaS CRDs and controller)"; \
		oc wait datasciencecluster "$$DSC" --for=condition=AIGatewayReady --timeout=600s; \
	fi; \
	echo "   Waiting for MaaS CRDs and maas-api in $$MAAS_API_NS"; \
	oc wait --for=create crd/maasmodelrefs.maas.opendatahub.io --timeout=600s; \
	oc wait --for=create deployment/maas-api -n "$$MAAS_API_NS" --timeout=600s; \
	oc rollout status deployment/maas-api -n "$$MAAS_API_NS" --timeout=300s; \
	echo "   Waiting for $$MAAS_READY_COND"; \
	oc wait datasciencecluster "$$DSC" --for=condition=$$MAAS_READY_COND --timeout=600s
	@echo "✅ MaaS components Ready"

.PHONY: setup-telemetry
setup-telemetry:
	@echo "== Usage telemetry (per user / group / model token metrics) =="
	@if oc get crd maastenantconfigs.maas.opendatahub.io >/dev/null 2>&1; then \
		oc wait --for=create maastenantconfig/default-tenant -n $(MAAS_NS) --timeout=300s; \
		oc patch maastenantconfig default-tenant -n $(MAAS_NS) --type=merge \
			-p '{"spec":{"telemetry":{"enabled":true,"metrics":{"captureGroup":true,"captureModelUsage":true,"captureOrganization":true,"captureUser":true}}}}'; \
	else \
		echo "   MaasTenantConfig not available on this RHOAI version, skipping"; \
	fi

.PHONY: health
health:
	@echo "== maas-api health: https://$(MAAS_HOSTNAME)/maas-api/health =="
	@# 1) Through the gateway's own address: proves the cluster side works, independent of DNS
	@ADDR=$$(oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{.status.addresses[0].value}' 2>/dev/null); \
	[ -n "$$ADDR" ] || { echo "❌ maas-default-gateway has no address (run make enable-maas)"; exit 1; }; \
	for i in $$(seq 1 $(HEALTH_RETRIES)); do \
		code=$$(curl -sk -o /dev/null -w '%{http_code}' --connect-to $(MAAS_HOSTNAME):443:$$ADDR:443 https://$(MAAS_HOSTNAME)/maas-api/health); \
		case $$code in 200|401) echo "✅ Gateway ($$ADDR): HTTP $$code"; break;; esac; \
		[ $$i = $(HEALTH_RETRIES) ] && { echo "❌ maas-api not reachable through the gateway (HTTP $$code)"; exit 1; }; \
		echo "   HTTP $$code (load balancer may still be provisioning), retrying..."; sleep 10; \
	done
	@# 2) Through public DNS: a re-created gateway gets a new load balancer, and resolvers may cache the old one
	@code=$$(curl -sk -o /dev/null -w '%{http_code}' https://$(MAAS_HOSTNAME)/maas-api/health); \
	case $$code in 200|401) echo "✅ https://$(MAAS_HOSTNAME): HTTP $$code";; \
		*) echo "⚠️  https://$(MAAS_HOSTNAME) returns HTTP $$code from this machine, but the gateway is healthy."; \
		   echo "   DNS here still points at an old load balancer; retry in a few minutes or flush your DNS cache.";; esac

# ---------------------------------------------------------------- disable
.PHONY: disable-maas
disable-maas: check
	@$(LOAD_ENV); \
	echo "This removes MaaS: all MaaSModelRef/MaaSAuthPolicy/MaaSSubscription, all API keys (PostgreSQL),"; \
	echo "maas-default-gateway, and sets $$MAAS_COMPONENT.$$MAAS_FIELD=Removed. Models (LLMInferenceService) are kept."; \
	if [ "$(FULL)" = "true" ]; then echo "FULL=true: also removes Kuadrant (kuadrant-system) and the openshift-default GatewayClass."; fi; \
	if [ -z "$(YES)" ]; then read -r -p "Continue? [y/N] " a; [ "$$a" = "y" ] || exit 1; fi; \
	echo "== Delete MaaS model registrations (their API keys are revoked) =="; \
	oc delete maassubscription,maasauthpolicy --all -n $(MAAS_NS) --ignore-not-found 2>/dev/null || true; \
	oc delete maasmodelref --all -A --ignore-not-found 2>/dev/null || true; \
	oc delete externalmodel --all -A --ignore-not-found 2>/dev/null || true; \
	echo "== DataScienceCluster/$$DSC: $$MAAS_COMPONENT.$$MAAS_FIELD -> Removed =="; \
	oc patch datasciencecluster "$$DSC" --type=merge -p "{\"spec\":{\"components\":{\"$$MAAS_COMPONENT\":{\"$$MAAS_FIELD\":{\"managementState\":\"Removed\"}}}}}"; \
	oc wait deployment/maas-api -n "$$MAAS_API_NS" --for=delete --timeout=300s 2>/dev/null || true; \
	for r in tenants.maas.opendatahub.io maastenantconfigs.maas.opendatahub.io; do \
		for o in $$(oc get $$r -n $(MAAS_NS) -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{" "}{end}' 2>/dev/null); do \
			echo "   $$r/$$o stuck terminating, removing finalizers"; \
			oc patch $$r $$o -n $(MAAS_NS) --type=merge -p '{"metadata":{"finalizers":[]}}'; \
		done; \
	done; \
	echo "== Delete PostgreSQL created by maas-helper =="; \
	oc delete deployment,service,secret,pvc -n "$$MAAS_API_NS" -l $(OWNED); \
	echo "== Delete MaaS gateway and its policies =="; \
	oc delete gateway maas-default-gateway -n openshift-ingress --ignore-not-found; \
	oc delete configmap maas-gateway-options -n openshift-ingress --ignore-not-found; \
	oc delete authpolicy maas-gateway-auth -n openshift-ingress --ignore-not-found; \
	oc delete tokenratelimitpolicy -n openshift-ingress -l app.kubernetes.io/part-of=models-as-a-service --ignore-not-found
	@if [ "$(FULL)" = "true" ]; then \
		echo "== FULL: delete Kuadrant and the openshift-default GatewayClass =="; \
		echo "⚠️  Kuadrant policies on other gateways (e.g. openshift-ai-inference auth) stop being enforced"; \
		oc delete kuadrant kuadrant -n kuadrant-system --ignore-not-found --wait=true; \
		oc delete namespace kuadrant-system --ignore-not-found; \
		if ! oc get gateway -A -o jsonpath='{.items[*].spec.gatewayClassName}' | grep -qw openshift-default; then \
			oc delete gatewayclass openshift-default --ignore-not-found; \
		fi; \
	fi
	@echo "✅ MaaS disabled"

# ---------------------------------------------------------------- status
.PHONY: status
status: check
	@echo "== DataScienceCluster conditions =="
	@oc get datasciencecluster -o jsonpath='{range .items[0].status.conditions[*]}{.type}={.status}{"\n"}{end}' \
		| grep -E '^(Ready|KserveReady|AIGatewayReady|ModelsAsA?ServiceReady)=' | sed 's/^/   /'
	@echo "== Kuadrant =="
	@oc get kuadrant kuadrant -n kuadrant-system >/dev/null 2>&1 \
		&& oc get kuadrant,authorino,limitador -n kuadrant-system || echo "   (not installed)"
	@echo "== Gateway =="
	@oc get gateway maas-default-gateway -n openshift-ingress 2>/dev/null || echo "   (no maas-default-gateway)"
	@$(LOAD_ENV); echo "== maas-api / postgres ($$MAAS_API_NS) =="; \
		oc get deployment maas-api postgres -n "$$MAAS_API_NS" 2>/dev/null || true
	@echo "== Published models =="
	@oc get maasmodelref -A 2>/dev/null || true
	@oc get maasauthpolicy,maassubscription -n $(MAAS_NS) 2>/dev/null || true
	@$(MAKE) --no-print-directory health HEALTH_RETRIES=1 || true

# ---------------------------------------------------------------- optional: sample model
.PHONY: deploy-sample-model
deploy-sample-model:
	@echo "== Sample model qwen3-0-6b (CPU) in $(SAMPLE_NS) =="
	oc apply -f $(BASE)/yaml/sample/qwen3-0.6b.yaml
	@echo "   Waiting for the model to be Ready (download + vLLM start take ~5 min; watch: oc get pods -n $(SAMPLE_NS))"
	@oc wait --for=create maasmodelref/qwen3-0-6b -n $(SAMPLE_NS) --timeout=60s
	@oc wait --for=jsonpath='{.status.phase}'=Ready maasmodelref/qwen3-0-6b -n $(SAMPLE_NS) --timeout=900s
	@echo "✅ qwen3-0-6b published. Run: make test-maas"

.PHONY: test-maas
test-maas:
	@$(BASE)/scripts/test-maas.sh $(MAAS_HOSTNAME) $(SAMPLE_SUBSCRIPTION)

.PHONY: delete-sample-model
delete-sample-model:
	oc delete -f $(BASE)/yaml/sample/qwen3-0.6b.yaml --ignore-not-found
