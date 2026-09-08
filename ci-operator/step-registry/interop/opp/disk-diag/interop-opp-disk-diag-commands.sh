#!/bin/bash
# ---------------------------------------------------------------------------
# OPP disk-layout diagnostic step
#
# Captures disk layout and ephemeral-storage information from cluster
# nodes to help diagnose why the RHCOS root filesystem may not be
# expanding to fill the configured EBS volume.  This is a best-effort
# diagnostic step -- it must never fail the chain.
#
# Uses only unprivileged oc commands (no node debug sessions).
# ---------------------------------------------------------------------------

set -eux -o pipefail; shopt -s inherit_errexit

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

typeset diagDir=''
diagDir="${ARTIFACT_DIR}/disk-diag"
typeset summary=''
summary="${ARTIFACT_DIR}/disk-diagnostics.txt"
mkdir -p "${diagDir}"

echo "=== OPP Disk Diagnostics ===" | tee "${summary}"

# -----------------------------------------------------------------------
# 1. Node capacity and allocatable ephemeral-storage (from the API)
# -----------------------------------------------------------------------
echo "" | tee -a "${summary}"
echo "--- Node ephemeral-storage capacity & allocatable ---" | tee -a "${summary}"

typeset nodeJson=''
nodeJson="$(oc get nodes -o json 2>/dev/null)"
if [[ -n "${nodeJson:-}" ]]; then
    echo "${nodeJson}" > "${diagDir}/nodes-full.json"

    python3 -c "
import json, sys

data = json.load(sys.stdin)
fmt = '  {name:<55} {role:<8} {cap:>14} {alloc:>14} {avail:>14}'
print(fmt.format(name='NODE', role='ROLE', cap='CAPACITY', alloc='ALLOCATABLE', avail='AVAIL(Ki)'))
print('  ' + '-' * 105)
for node in data.get('items', []):
    name = node['metadata']['name']
    labels = node['metadata'].get('labels', {})
    role = 'worker' if 'node-role.kubernetes.io/worker' in labels else \
           'master' if 'node-role.kubernetes.io/master' in labels else 'other'
    cap = node.get('status', {}).get('capacity', {}).get('ephemeral-storage', 'n/a')
    alloc = node.get('status', {}).get('allocatable', {}).get('ephemeral-storage', 'n/a')

    # Convert to Ki for readability if the value is in bytes (bare number)
    def to_ki(val):
        if val == 'n/a':
            return val
        try:
            if val.endswith('Ki'):
                return val
            elif val.endswith('Mi'):
                return str(int(val[:-2]) * 1024) + 'Ki'
            elif val.endswith('Gi'):
                return str(int(val[:-2]) * 1024 * 1024) + 'Ki'
            else:
                return str(int(val) // 1024) + 'Ki'
        except (ValueError, TypeError):
            return val

    cap_ki = to_ki(cap)
    alloc_ki = to_ki(alloc)

    # Compute approximate available vs 10% eviction threshold
    avail_note = ''
    try:
        if cap.endswith('Ki'):
            cap_bytes = int(cap[:-2]) * 1024
        elif cap.endswith('Mi'):
            cap_bytes = int(cap[:-2]) * 1024 * 1024
        elif cap.endswith('Gi'):
            cap_bytes = int(cap[:-2]) * 1024 * 1024 * 1024
        else:
            cap_bytes = int(cap)
        threshold_10pct = cap_bytes * 0.10
        avail_note = '(10%%_threshold=%dKi)' % (threshold_10pct // 1024)
    except (ValueError, TypeError):
        pass

    print(fmt.format(name=name[:55], role=role, cap=cap_ki, alloc=alloc_ki, avail=avail_note))
" <<< "${nodeJson}" 2>&1 | tee -a "${summary}"
else
    echo "  WARNING: Failed to fetch nodes" | tee -a "${summary}"
fi

# -----------------------------------------------------------------------
# 2. oc adm top nodes — actual resource usage
# -----------------------------------------------------------------------
echo "" | tee -a "${summary}"
echo "--- Node resource usage (oc adm top nodes) ---" | tee -a "${summary}"
typeset topOutput=''
topOutput="$(oc adm top nodes --no-headers 2>&1)"
if [[ -z "${topOutput:-}" ]] || [[ "${topOutput}" == *"error"* ]] || [[ "${topOutput}" == *"Error"* ]]; then
    echo "  WARNING: oc adm top nodes failed: ${topOutput}" | tee -a "${summary}"
else
    echo "${topOutput}" | tee -a "${summary}"
    echo "${topOutput}" > "${diagDir}/top-nodes.txt"
fi

# -----------------------------------------------------------------------
# 3. Node conditions — look for DiskPressure or MemoryPressure
# -----------------------------------------------------------------------
echo "" | tee -a "${summary}"
echo "--- Node pressure conditions ---" | tee -a "${summary}"
if [[ -n "${nodeJson:-}" ]]; then
    python3 -c "
import json, sys

data = json.load(sys.stdin)
found = False
for node in data.get('items', []):
    name = node['metadata']['name']
    conditions = node.get('status', {}).get('conditions', [])
    for cond in conditions:
        ctype = cond.get('type', '')
        if ctype in ('DiskPressure', 'MemoryPressure', 'PIDPressure') and cond.get('status') == 'True':
            found = True
            print(f'  WARNING: {name}: {ctype}=True reason={cond.get(\"reason\",\"\")} message={cond.get(\"message\",\"\")}')
if not found:
    print('  No pressure conditions detected on any node')
" <<< "${nodeJson}" 2>&1 | tee -a "${summary}"
fi

# -----------------------------------------------------------------------
# 4. KubeletConfiguration (cluster-level)
# -----------------------------------------------------------------------
echo "" | tee -a "${summary}"
echo "--- KubeletConfig CRs ---" | tee -a "${summary}"
typeset kcOutput=''
kcOutput="$(oc get kubeletconfigs -o yaml 2>&1)"
if [[ -n "${kcOutput:-}" ]]; then
    echo "${kcOutput}" > "${diag_dir}/kubeletconfig.yaml"
    echo "  Saved to ${diag_dir}/kubeletconfig.yaml" | tee -a "${summary}"
else
    echo "  No KubeletConfig CRs found or query failed" | tee -a "${summary}"
fi

# -----------------------------------------------------------------------
# 5. MachineConfigPool status
# -----------------------------------------------------------------------
echo "" | tee -a "${summary}"
echo "--- MachineConfigPool status ---" | tee -a "${summary}"
typeset mcpOutput=''
mcpOutput="$(oc get mcp -o wide 2>&1)"
if [[ -z "${mcpOutput:-}" ]] || [[ "${mcpOutput}" == *"error"* ]] || [[ "${mcpOutput}" == *"Error"* ]]; then
    echo "  WARNING: oc get mcp failed: ${mcpOutput}" | tee -a "${summary}"
else
    echo "${mcpOutput}" | tee -a "${summary}"
    echo "${mcpOutput}" > "${diagDir}/mcp-status.txt"
fi

# -----------------------------------------------------------------------
# 6. Pod eviction events (ephemeral-storage related)
# -----------------------------------------------------------------------
echo "" | tee -a "${summary}"
echo "--- Recent eviction events ---" | tee -a "${summary}"
typeset events=''
events="$(oc get events --all-namespaces --field-selector reason=Evicted -o json 2>/dev/null)"
if [[ -n "${events:-}" ]]; then
    echo "${events}" > "${diagDir}/eviction-events.json"
    python3 -c "
import json, sys

data = json.load(sys.stdin)
items = data.get('items', [])
if not items:
    print('  No eviction events found')
else:
    print(f'  Found {len(items)} eviction event(s):')
    for ev in items[:20]:
        ns = ev.get('involvedObject', {}).get('namespace', '')
        name = ev.get('involvedObject', {}).get('name', '')
        msg = ev.get('message', '')[:120]
        ts = ev.get('lastTimestamp', ev.get('eventTime', ''))
        print(f'    {ts} {ns}/{name}: {msg}')
    if len(items) > 20:
        print(f'    ... and {len(items) - 20} more (see eviction-events.json)')
" <<< "${events}" 2>&1 | tee -a "${summary}"
else
    echo "  WARNING: Failed to query eviction events" | tee -a "${summary}"
fi

echo "" | tee -a "${summary}"
echo "=== Disk diagnostics complete ===" | tee -a "${summary}"

true
