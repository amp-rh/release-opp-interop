#!/bin/bash

set -eux -o pipefail
shopt -s inherit_errexit

OPP_OPERATORS="${OPP_OPERATORS:-advanced-cluster-management,rhacs-operator,odf-operator,quay-operator}"

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman
mkdir -p "${XDG_RUNTIME_DIR}"

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    set +x
    source "${SHARED_DIR}/proxy-conf.sh"
    set -x
fi

REPORT_DIR="${ARTIFACT_DIR}/preflight"
REPORT_FILE="${REPORT_DIR}/preflight-report.json"
mkdir -p "${REPORT_DIR}"

typeset -i CHECKS_FAILED=0
typeset -i EXIT_CODE=0

function debugOnExit() {
    if (( EXIT_CODE != 0 )); then
        : "### DEBUG: Pre-flight failure diagnostics ###"
        : "# ClusterVersion"
        oc get clusterversion 2>/dev/null || : "unavailable"
        : "# ClusterOperators"
        oc get co 2>/dev/null || : "unavailable"
        : "# MachineConfigPools"
        oc get machineconfigpools 2>/dev/null || : "unavailable"
        : "# Nodes"
        oc get nodes 2>/dev/null || : "unavailable"
        : "# OPP Operator CSVs"
        oc get csv -A 2>/dev/null || : "unavailable"
        if [[ -f "${REPORT_FILE}" ]]; then
            : "# Pre-flight report:"
            cat "${REPORT_FILE}"
        fi
    fi
    true
}

trap '{ EXIT_CODE=$?; debugOnExit; true; }' EXIT
trap '{ EXIT_CODE=143; debugOnExit; trap - EXIT; exit 143; }' TERM

# ──────────────────────────────────────────────────────────────────────
#  Known removed / deprecated APIs per OCP minor version.
#  Each entry lists the API group/version and the resource kind that
#  was removed IN that minor version (i.e. no longer available).
#  Source: Kubernetes deprecation guide + OCP release notes.
# ──────────────────────────────────────────────────────────────────────
typeset -A removedApis
removedApis["12"]="batch/v1beta1/CronJob policy/v1beta1/PodDisruptionBudget policy/v1beta1/PodSecurityPolicy discovery.k8s.io/v1beta1/EndpointSlice events.k8s.io/v1beta1/Event autoscaling/v2beta1/HorizontalPodAutoscaler"
removedApis["14"]="storage.k8s.io/v1beta1/CSIStorageCapacity"
removedApis["17"]="flowcontrol.apiserver.k8s.io/v1beta2/FlowSchema flowcontrol.apiserver.k8s.io/v1beta2/PriorityLevelConfiguration"
removedApis["18"]="flowcontrol.apiserver.k8s.io/v1beta3/FlowSchema flowcontrol.apiserver.k8s.io/v1beta3/PriorityLevelConfiguration"

# ──────────────────────────────────────────────────────────────────────
#  OPP operator compatibility matrix.
#  Maps OCP minor version to minimum required operator major.minor.
#  Format: "operator_csv_prefix:min_major.min_minor"
# ──────────────────────────────────────────────────────────────────────
typeset -A oppCompat
oppCompat["4.14"]="advanced-cluster-management:2.9 rhacs-operator:4.3 odf-operator:4.14 quay-operator:3.10"
oppCompat["4.15"]="advanced-cluster-management:2.10 rhacs-operator:4.4 odf-operator:4.15 quay-operator:3.11"
oppCompat["4.16"]="advanced-cluster-management:2.11 rhacs-operator:4.5 odf-operator:4.16 quay-operator:3.12"
oppCompat["4.17"]="advanced-cluster-management:2.12 rhacs-operator:4.6 odf-operator:4.17 quay-operator:3.13"
oppCompat["4.18"]="advanced-cluster-management:2.13 rhacs-operator:4.7 odf-operator:4.18 quay-operator:3.14"
oppCompat["4.19"]="advanced-cluster-management:2.13 rhacs-operator:4.8 odf-operator:4.19 quay-operator:3.14"
oppCompat["4.20"]="advanced-cluster-management:2.14 rhacs-operator:4.9 odf-operator:4.20 quay-operator:3.15"
oppCompat["4.21"]="advanced-cluster-management:2.15 rhacs-operator:4.10 odf-operator:4.21 quay-operator:3.15"
oppCompat["4.22"]="advanced-cluster-management:2.17 rhacs-operator:4.11 odf-operator:4.21 quay-operator:3.16"
oppCompat["5.0"]="advanced-cluster-management:2.17 quay-operator:3.17 odf-operator:5.0 rhacs-operator:4.11"
oppCompat["5.1"]="advanced-cluster-management:2.17 quay-operator:3.18 odf-operator:5.1 rhacs-operator:4.12"

function initReport() {
    cat > "${REPORT_FILE}" <<'EOFJSON'
{
  "preflight_checks": []
}
EOFJSON
    true
}

function appendCheck() {
    typeset checkName
    checkName="${1}"
    typeset checkStatus
    checkStatus="${2}"
    typeset checkDetails
    checkDetails="${3}"
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
data['preflight_checks'].append({'check': sys.argv[2], 'status': sys.argv[3], 'details': sys.argv[4]})
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2)
" "${REPORT_FILE}" "${checkName}" "${checkStatus}" "${checkDetails}"
    true
}

function checkApiDeprecations() {
    : "=== Check 1: API deprecation scan ==="

    typeset targetMinor
    targetMinor="${1}"
    typeset ocpDisplay
    ocpDisplay="${2:-4.${targetMinor}}"
    typeset targetMajor
    targetMajor="${ocpDisplay%%.*}"
    typeset flagged
    flagged=""
    typeset foundCount
    foundCount=0

    typeset clusterApis
    clusterApis="$(oc api-resources --no-headers)" || {
        : "WARNING: Failed to list API resources"
        appendCheck "api_deprecation_scan" "warn" "Could not list cluster API resources"
        return 0
    }

    for minor in "${!removedApis[@]}"; do
        if (( targetMajor > 4 || minor <= targetMinor )); then
            for apiEntry in ${removedApis[${minor}]}; do
                typeset apiVersion
                apiVersion="${apiEntry%/*}"
                typeset apiKind
                apiKind="${apiEntry##*/}"

                if echo "${clusterApis}" | grep -qw "${apiKind}" && \
                   oc api-resources --api-group="${apiVersion%%/*}" 2>/dev/null | grep -q "${apiVersion#*/}"; then
                    typeset oppUsage
                    oppUsage="$(oc get "${apiKind}" -A --no-headers 2>/dev/null | head -5)" || true
                    if [[ -n "${oppUsage}" ]]; then
                        flagged="${flagged}  - ${apiVersion}/${apiKind} (removed in ${targetMajor}.${minor})\n"
                        (( foundCount += 1 ))
                    fi
                fi
            done
        fi
    done

    if (( foundCount > 0 )); then
        : "WARNING: Found ${foundCount} deprecated API(s) still in use"
        echo -e "${flagged}"
        appendCheck "api_deprecation_scan" "warn" "Found ${foundCount} deprecated API(s) in use: ${flagged}"
    else
        : "No deprecated APIs detected for target version ${ocpDisplay}"
        appendCheck "api_deprecation_scan" "pass" "No deprecated APIs detected for ${ocpDisplay}"
    fi
    true
}

function checkOppCompatibility() {
    : "=== Check 2: OPP operator compatibility matrix ==="

    typeset ocpKey
    ocpKey="${1}"
    typeset compatSpec
    compatSpec="${oppCompat[${ocpKey}]:-}"
    typeset allCsvs
    typeset failed
    failed=0

    allCsvs="$(oc get csv -A --no-headers)" || {
        : "Failed to retrieve CSVs"
        appendCheck "opp_compatibility_matrix" "fail" "Could not list CSVs"
        (( CHECKS_FAILED += 1 ))
        return 0
    }

    if [[ -z "${compatSpec}" ]]; then
        : "No compatibility matrix entry for OCP ${ocpKey}; skipping version check"
        appendCheck "opp_compatibility_matrix" "skip" "No matrix entry for OCP ${ocpKey}"
        return 0
    fi

    typeset details
    details=""
    for entry in ${compatSpec}; do
        typeset opPrefix
        opPrefix="${entry%%:*}"
        typeset minVersion
        minVersion="${entry##*:}"
        typeset minMajor
        minMajor="${minVersion%%.*}"
        typeset minMinor
        minMinor="${minVersion##*.}"

        typeset csvLine
        csvLine="$(echo "${allCsvs}" | grep "${opPrefix}" | head -1)" || true
        typeset csvName
        typeset installedVersion
        if [[ -z "${csvLine}" ]]; then
            : "Operator not found: ${opPrefix}"
            details="${details}${opPrefix}: NOT INSTALLED; "
            (( failed += 1 ))
            continue
        fi

        csvName="$(echo "${csvLine}" | awk '{print $2}')"
        installedVersion="$(echo "${csvName}" | grep -oE '[0-9]+\.[0-9]+' | head -1)" || true
        if [[ -z "${installedVersion}" ]]; then
            : "Operator ${opPrefix}: could not parse version from CSV ${csvName}"
            details="${details}${opPrefix}: version unparseable from ${csvName}; "
            (( failed += 1 ))
            continue
        fi

        typeset instMajor
        instMajor="${installedVersion%%.*}"
        typeset instMinor
        instMinor="${installedVersion##*.}"

        if (( instMajor < minMajor || (instMajor == minMajor && instMinor < minMinor) )); then
            : "Operator ${opPrefix} version ${installedVersion} is below minimum ${minVersion} for OCP ${ocpKey}"
            details="${details}${opPrefix}: ${installedVersion} < ${minVersion} (INCOMPATIBLE); "
            (( failed += 1 ))
        else
            : "Operator ${opPrefix}: version ${installedVersion} >= ${minVersion} (OK)"
            details="${details}${opPrefix}: ${installedVersion} >= ${minVersion} (OK); "
        fi
    done

    if (( failed > 0 )); then
        : "${failed} operator(s) failed compatibility check"
        appendCheck "opp_compatibility_matrix" "fail" "${details}"
        (( CHECKS_FAILED += 1 ))
    else
        : "All OPP operators are compatible with OCP ${ocpKey}"
        appendCheck "opp_compatibility_matrix" "pass" "${details}"
    fi
    true
}

function checkClusterHealth() {
    : "=== Check 3: Cluster health baseline ==="

    typeset failed
    failed=0
    typeset details
    details=""

    : "Checking node health..."
    typeset unreadyNodes
    if ! unreadyNodes="$(oc get node --no-headers | awk '$2 != "Ready" {print $1}')"; then
        : "Failed to query nodes"
        details="${details}nodes: query failed; "
        (( failed += 1 ))
    elif [[ -n "${unreadyNodes}" ]]; then
        : "Not-Ready nodes: ${unreadyNodes}"
        details="${details}unready_nodes: ${unreadyNodes}; "
        (( failed += 1 ))
    else
        typeset nodeCount
        nodeCount="$(oc get node --no-headers | wc -l)"
        : "All ${nodeCount} nodes Ready"
        details="${details}nodes: all ${nodeCount} ready; "
    fi

    : "Checking ClusterOperator health..."
    typeset unhealthyCo
    if ! unhealthyCo="$(oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}')"; then
        : "Failed to query ClusterOperators"
        details="${details}cluster_operators: query failed; "
        (( failed += 1 ))
    elif [[ -n "${unhealthyCo}" ]]; then
        : "Unhealthy ClusterOperators: ${unhealthyCo}"
        details="${details}unhealthy_co: ${unhealthyCo}; "
        (( failed += 1 ))
    else
        : "All ClusterOperators healthy"
        details="${details}cluster_operators: all healthy; "
    fi

    : "Checking ClusterVersion conditions..."
    typeset avail
    avail="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')" || true
    typeset progressing
    progressing="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')" || true
    typeset degraded
    degraded="$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}')" || true
    if [[ "${avail}" != "True" || ( -n "${progressing}" && "${progressing}" != "False" ) || ( -n "${degraded}" && "${degraded}" != "False" ) ]]; then
        : "CVO health check failed: Available=${avail} Progressing=${progressing} Degraded=${degraded}"
        details="${details}cvo: Available=${avail} Progressing=${progressing} Degraded=${degraded}; "
        (( failed += 1 ))
    else
        : "CVO: Available=True, Progressing=False, Degraded=False"
        details="${details}cvo: healthy; "
    fi

    : "Checking for firing alerts..."
    typeset firingAlerts
    if ! firingAlerts="$(oc -n openshift-monitoring exec -c prometheus prometheus-k8s-0 -- \
        curl -s 'http://localhost:9090/api/v1/alerts' | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
if data.get('status') != 'success':
    print('query returned non-success status', file=sys.stderr)
    sys.exit(1)
alerts = data.get('data', {}).get('alerts', [])
names = sorted(set(
    a['labels']['alertname'] for a in alerts
    if a.get('state') == 'firing'
    and a.get('labels', {}).get('alertname') not in ('Watchdog', 'AlertmanagerReceiversNotConfigured')
))
print('\n'.join(names))
")"; then
        : "Alert query failed or unavailable"
        details="${details}alerts: query failed; "
    elif [[ -n "${firingAlerts}" ]]; then
        typeset alertCount
        alertCount="$(echo "${firingAlerts}" | wc -l)"
        : "WARNING: ${alertCount} alert(s) firing: ${firingAlerts}"
        details="${details}firing_alerts: ${alertCount} (${firingAlerts}); "
    else
        : "No critical alerts firing"
        details="${details}alerts: none firing; "
    fi

    oc get nodes -o json > "${REPORT_DIR}/nodes-baseline.json" 2>/dev/null || true
    oc get co -o json > "${REPORT_DIR}/co-baseline.json" 2>/dev/null || true

    if (( failed > 0 )); then
        : "Cluster health baseline: ${failed} issue(s) found"
        appendCheck "cluster_health_baseline" "fail" "${details}"
        (( CHECKS_FAILED += 1 ))
    else
        : "Cluster health baseline: all checks passed"
        appendCheck "cluster_health_baseline" "pass" "${details}"
    fi
    true
}

function checkMcpReadiness() {
    : "=== Check 4: MachineConfigPool readiness ==="

    typeset failed
    failed=0
    typeset details
    details=""

    typeset mcpRaw
    if ! mcpRaw="$(oc get machineconfigpools --no-headers 2>&1)"; then
        : "Failed to query MachineConfigPools"
        details="machineconfigpools: query failed; "
        (( failed += 1 ))
    else
        typeset mcpIssues
        mcpIssues="$(echo "${mcpRaw}" | \
            awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}')" || true

        if [[ -n "${mcpIssues}" ]]; then
            : "Unhealthy MachineConfigPools: ${mcpIssues}"
            details="unhealthy_mcps: ${mcpIssues}; "
            (( failed += 1 ))

            for mcp in ${mcpIssues}; do
                : "### MCP ${mcp} ###"
                oc describe machineconfigpool "${mcp}" || true
            done
        else
            typeset mcpCount
            mcpCount="$(echo "${mcpRaw}" | wc -l)"
            : "All ${mcpCount} MachineConfigPools are updated and not degraded"
            details="all ${mcpCount} MCPs healthy (Updated=True, Updating=False, Degraded=False); "
        fi
    fi

    typeset mismatch
    mismatch=""
    if [[ -n "${mcpRaw:-}" ]]; then
        while IFS= read -r line; do
            typeset mcpName
            mcpName="$(echo "${line}" | awk '{print $1}')"
            typeset ready
            ready="$(echo "${line}" | awk '{print $7}')"
            typeset desired
            desired="$(echo "${line}" | awk '{print $6}')"
            if [[ -n "${ready}" && -n "${desired}" && "${ready}" != "${desired}" ]]; then
                mismatch="${mismatch}${mcpName} (ready=${ready}, desired=${desired}); "
            fi
        done <<< "${mcpRaw}"
    fi

    if [[ -n "${mismatch}" ]]; then
        : "MCP machine count mismatch: ${mismatch}"
        details="${details}machine_count_mismatch: ${mismatch}"
        (( failed += 1 ))
    fi

    oc get machineconfigpools -o json > "${REPORT_DIR}/mcp-baseline.json" 2>/dev/null || true

    if (( failed > 0 )); then
        : "MachineConfigPool readiness: ${failed} issue(s) found"
        appendCheck "mcp_readiness" "fail" "${details}"
        (( CHECKS_FAILED += 1 ))
    else
        : "MachineConfigPool readiness: all checks passed"
        appendCheck "mcp_readiness" "pass" "${details}"
    fi
    true
}

function main() {
    if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    typeset target
    target="${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE:-}"
    if [[ -z "${target}" ]]; then
        : "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE is not set; cannot determine upgrade target"
        exit 3
    fi
    : "Target release image: ${target}"

    set +x
    KUBECONFIG="" oc registry login
    set -x

    typeset targetVersion
    targetVersion="$(oc adm release info "${target}" -o jsonpath='{.metadata.version}')"
    typeset targetMajor
    targetMajor="$(echo "${targetVersion}" | cut -f1 -d.)"
    typeset targetMinor
    targetMinor="$(echo "${targetVersion}" | cut -f2 -d.)"
    typeset ocpXy
    ocpXy="${targetMajor}.${targetMinor}"
    : "Target OCP version: ${targetVersion} (${ocpXy})"

    typeset sourceVersion
    sourceVersion="$(oc get clusterversion --no-headers | awk '{print $2}')"
    : "Source OCP version: ${sourceVersion}"

    : "=== Starting OPP pre-flight validation ==="

    initReport

    python3 -c "
import json, sys, time
with open(sys.argv[1]) as f:
    data = json.load(f)
data['target_version'] = sys.argv[2]
data['source_version'] = sys.argv[3]
data['target_image'] = sys.argv[4]
data['timestamp'] = str(time.time())
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2)
" "${REPORT_FILE}" "${targetVersion}" "${sourceVersion}" "${target}"

    checkApiDeprecations "${targetMinor}" "${ocpXy}"
    checkOppCompatibility "${ocpXy}"
    checkClusterHealth
    checkMcpReadiness

    : "=== Pre-flight summary ==="
    python3 -m json.tool "${REPORT_FILE}"

    if (( CHECKS_FAILED > 0 )); then
        : "Pre-flight validation FAILED: ${CHECKS_FAILED} check(s) did not pass"
        : "Review ${REPORT_FILE} for details"
        exit 3
    fi

    : "Pre-flight validation PASSED: all checks succeeded"
    true
}

main "$@"
