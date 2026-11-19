#!/usr/bin/env bash
# Checks MaaS prerequisites: oc login, required operators, Gateway API, DSC/DSCI.
#   check-dsc.sh       print a human-readable report (exit 1 if a prerequisite is missing)
#   check-dsc.sh env   print KEY=VALUE lines for the Makefile (eval "$(check-dsc.sh env)")
set -euo pipefail

MODE="${1:-report}"

say() { [[ "$MODE" == "report" ]] && echo "$@" || true; }
fail() { echo "❌ $*" >&2; exit 1; }

# 1. Logged in?
oc whoami >/dev/null 2>&1 || fail "Not logged in. Run 'oc login' first."
say "✅ Logged in as $(oc whoami) on $(oc whoami --show-server)"

# 2. Required operators (Subscription package -> display name). maas-helper does not install these.
SUBS=$(oc get subscription -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.spec.name} {.status.installedCSV}{"\n"}{end}')
for op in "rhods-operator:Red Hat OpenShift AI" \
          "rhcl-operator:Red Hat Connectivity Link" \
          "authorino-operator:Authorino" \
          "limitador-operator:Limitador"; do
    pkg="${op%%:*}"; name="${op#*:}"
    read -r ns csv < <(awk -v p="$pkg" '$2==p {print $1, $3; exit}' <<<"$SUBS") || true
    phase=$(oc get csv "${csv:-none}" -n "${ns:-default}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$phase" != "Succeeded" ]]; then
        # Show why OLM could not install it (e.g. ResolutionFailed from a version conflict)
        why=$(oc get subscription -A -o jsonpath="{range .items[?(@.spec.name==\"$pkg\")]}{range .status.conditions[?(@.status==\"True\")]}{.type}: {.message}{end}{end}" 2>/dev/null | cut -c1-300)
        fail "$name operator not installed (Subscription '$pkg' with a Succeeded CSV). Install it from OperatorHub.${why:+
   OLM says: $why}"
    fi
    say "✅ $name: $csv"
    if [[ "$pkg" == "rhods-operator" ]]; then RHOAI_VERSION=$(sed -E 's/^rhods-operator\.v?//' <<<"$csv"); fi
done

# 3. MaaS needs Istio for its gateway. OpenShift 4.19+ deploys it; older versions need Service Mesh 3.
OCP=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
if [[ "$(printf '%s\n4.19\n' "$OCP" | sort -V | head -1)" == "4.19" ]]; then
    say "✅ OpenShift $OCP provides Istio for the Gateway API"
elif awk '$2=="servicemeshoperator3" && $3!=""' <<<"$SUBS" | grep -q .; then
    say "✅ OpenShift $OCP with Service Mesh 3 for the Gateway API"
else
    fail "OpenShift $OCP needs Red Hat OpenShift Service Mesh 3 (or upgrade to 4.19+)."
fi

# 4. DSCInitialization and DataScienceCluster must exist. A default DSC is fine.
DSCI=$(oc get dscinitialization -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$DSCI" ]] || fail "No DSCInitialization found. Create one from the OpenShift AI operator page."
DSC=$(oc get datasciencecluster -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$DSC" ]] || fail "No DataScienceCluster found. Create one from the OpenShift AI operator page."
say "✅ DSCInitialization/$DSCI and DataScienceCluster/$DSC exist"
# MaaS serves models through KServe; 'make enable-maas' turns it on if needed.
KSERVE=$(oc get datasciencecluster "$DSC" -o jsonpath='{.spec.components.kserve.managementState}')
[[ "$KSERVE" == "Managed" ]] || say "ℹ️  DSC kserve is '${KSERVE:-unset}'; enable-maas will set it to Managed."
# Unrelated components (e.g. trainer without the JobSet operator) can keep the DSC not Ready; MaaS does not care.
DSC_READY=$(oc get datasciencecluster "$DSC" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
if [[ "$DSC_READY" != "True" ]]; then
    NOT_READY=$(oc get datasciencecluster "$DSC" -o jsonpath='{range .status.conditions[?(@.status=="False")]}{.type}{" "}{end}')
    say "⚠️  DataScienceCluster/$DSC not Ready (False: ${NOT_READY:-none}). OK unless KserveReady is listed."
fi

# 5. The MaaS switch moved in RHOAI 3.5: kserve.modelsAsService -> aigateway.modelsAsAService.
if [[ "$(printf '%s\n3.5\n' "$RHOAI_VERSION" | sort -V | head -1)" == "3.5" ]]; then
    MAAS_COMPONENT=aigateway; MAAS_FIELD=modelsAsAService
    MAAS_READY_COND=ModelsAsAServiceReady; MAAS_API_NS=redhat-ai-gateway-infra
else
    MAAS_COMPONENT=kserve; MAAS_FIELD=modelsAsService
    MAAS_READY_COND=ModelsAsServiceReady; MAAS_API_NS=redhat-ods-applications
fi
MAAS_STATE=$(oc get datasciencecluster "$DSC" -o jsonpath="{.spec.components.$MAAS_COMPONENT.$MAAS_FIELD.managementState}")
MAAS_READY=$(oc get datasciencecluster "$DSC" -o jsonpath="{.status.conditions[?(@.type==\"$MAAS_READY_COND\")].status}")

# 6. RHOAI 3.5: llamastackoperator and ogx must not both be Managed, or aigateway CRDs never install.
if [[ "$MAAS_COMPONENT" == "aigateway" ]]; then
    LLS=$(oc get datasciencecluster "$DSC" -o jsonpath='{.spec.components.llamastackoperator.managementState}')
    OGX=$(oc get datasciencecluster "$DSC" -o jsonpath='{.spec.components.ogx.managementState}')
    if [[ "$LLS" == "Managed" && "$OGX" == "Managed" ]]; then
        fail "DSC has both llamastackoperator and ogx Managed. Set llamastackoperator to Removed."
    fi
fi

if [[ "$MODE" == "env" ]]; then
    cat <<EOF
DSC=$DSC
RHOAI_VERSION=$RHOAI_VERSION
MAAS_COMPONENT=$MAAS_COMPONENT
MAAS_FIELD=$MAAS_FIELD
MAAS_READY_COND=$MAAS_READY_COND
MAAS_API_NS=$MAAS_API_NS
MAAS_STATE=${MAAS_STATE:-Removed}
EOF
    exit 0
fi

say "✅ RHOAI $RHOAI_VERSION: MaaS switch is spec.components.$MAAS_COMPONENT.$MAAS_FIELD"
if [[ "$MAAS_STATE" == "Managed" ]]; then
    say "✅ MaaS is Managed ($MAAS_READY_COND=${MAAS_READY:-<none>})"
else
    say "ℹ️  MaaS is off (${MAAS_STATE:-not set in DSC}). Run 'make enable-maas'."
fi
