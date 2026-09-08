#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

function PropagatJunit () {
    mkdir -p "${SHARED_DIR}/junit"
    find "${ARTIFACT_DIR}" -name '*.xml' -exec cp {} "${SHARED_DIR}/junit/" \; 2>/dev/null
}
trap '{( PropagatJunit; )}' EXIT

if [[ -f "${SHARED_DIR}/kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

echo "[smoke] Reading connection details from SHARED_DIR..."

typeset centralUrl
centralUrl="$(cat "${SHARED_DIR}/CENTRAL_URL")"
typeset roxAdminPassword
roxAdminPassword="$(cat "${SHARED_DIR}/ROX_ADMIN_PASSWORD")"

echo "[smoke] Connection details loaded from SHARED_DIR"

STACKROX_REF="${STACKROX_REF:-master}"
SCANNER_REF="${SCANNER_REF:-master}"

echo "[smoke] Sparse-cloning stackrox/stackrox..."
cd /tmp
rm -rf stackrox scanner
git clone --depth 1 --filter=blob:none --sparse --branch "${STACKROX_REF}" \
    https://github.com/stackrox/stackrox.git stackrox
cd stackrox
git sparse-checkout set qa-tests-backend/ proto/

echo "[smoke] Fetching scanner protos..."
git clone --depth 1 --filter=blob:none --sparse --branch "${SCANNER_REF}" \
    https://github.com/stackrox/scanner.git /tmp/scanner
cd /tmp/scanner
git sparse-checkout set proto/scanner
cp -r proto/scanner /tmp/stackrox/qa-tests-backend/src/main/proto/scanner
chmod -R u+w /tmp/stackrox/qa-tests-backend/src/main/proto/scanner

echo "[smoke] Materializing proto sources (replace symlinks with copies)..."
cd /tmp/stackrox/qa-tests-backend/src/main/proto
typeset target
for link in api internalapi storage test tools; do
    if [[ -L "${link}" ]]; then
        target=$(readlink -f "${link}")
        rm "${link}"
        cp -r "${target}" "${link}"
    fi
done

echo "[smoke] Patching DEFAULT_CLUSTER_NAME to 'local-cluster'..."
sed -i 's/DEFAULT_CLUSTER_NAME = "remote"/DEFAULT_CLUSTER_NAME = "local-cluster"/' \
    /tmp/stackrox/qa-tests-backend/src/main/groovy/services/ClusterService.groovy
grep -q 'DEFAULT_CLUSTER_NAME = "local-cluster"' \
    /tmp/stackrox/qa-tests-backend/src/main/groovy/services/ClusterService.groovy \
    || { echo "[smoke] FATAL: DEFAULT_CLUSTER_NAME patch failed"; exit 1; }

export API_HOSTNAME="${centralUrl}"
export API_PORT="443"
export ROX_USERNAME="admin"
export ROX_ADMIN_PASSWORD="${roxAdminPassword}"
export CLUSTER="OPENSHIFT"
export CI="true"
export POD_SECURITY_POLICIES="false"
export TEST_TARGET="smoke-test"
typeset registryUsername
registryUsername="$(cat /tmp/vault/stackrox-stackrox-e2e-tests/QUAY_RHACS_ENG_RO_USERNAME)"
export REGISTRY_USERNAME="${registryUsername}"
typeset registryPassword
registryPassword="$(cat /tmp/vault/stackrox-stackrox-e2e-tests/QUAY_RHACS_ENG_RO_PASSWORD)"
export REGISTRY_PASSWORD="${registryPassword}"
if [[ -f /tmp/vault/stackrox-stackrox-e2e-tests/GOOGLE_CREDENTIALS_GCR_SCANNER_V2 ]]; then
    typeset googleCredentialsGcrScannerV2
    googleCredentialsGcrScannerV2="$(cat /tmp/vault/stackrox-stackrox-e2e-tests/GOOGLE_CREDENTIALS_GCR_SCANNER_V2)"
    export GOOGLE_CREDENTIALS_GCR_SCANNER_V2="${googleCredentialsGcrScannerV2}"
fi
if [[ -f /tmp/vault/stackrox-stackrox-e2e-tests/GOOGLE_ARTIFACT_REGISTRY_SERVICE_ACCOUNT_V2 ]]; then
    typeset googleArtifactRegistryServiceAccountV2
    googleArtifactRegistryServiceAccountV2="$(cat /tmp/vault/stackrox-stackrox-e2e-tests/GOOGLE_ARTIFACT_REGISTRY_SERVICE_ACCOUNT_V2)"
    export GOOGLE_ARTIFACT_REGISTRY_SERVICE_ACCOUNT_V2="${googleArtifactRegistryServiceAccountV2}"
fi

cd /tmp/stackrox/qa-tests-backend

cat > /tmp/fix-proto-deps.gradle <<'INIT'
allprojects {
    afterEvaluate {
        tasks.matching { it.name == 'compileGroovy' }.configureEach {
            dependsOn tasks.matching { it.name == 'generateProto' }
        }
    }
}
INIT

echo "[smoke] Running testSMOKE..."
typeset -i testExit
testExit=0
if ! ./gradlew testSMOKE --no-daemon --init-script /tmp/fix-proto-deps.gradle \
    -Dorg.gradle.jvmargs="-Xmx2g"; then
    testExit=$?
fi

echo "[smoke] Copying JUnit results to ARTIFACT_DIR..."
if [[ -d build/test-results/testSMOKE ]]; then
    find build/test-results/testSMOKE -name '*.xml' -exec cp -v {} "${ARTIFACT_DIR}/" \;
fi

if [[ -d build/reports/tests/testSMOKE ]]; then
    mkdir -p "${ARTIFACT_DIR}/smoke-report"
    find build/reports/tests/testSMOKE -mindepth 1 -maxdepth 1 \
        -exec cp -r {} "${ARTIFACT_DIR}/smoke-report/" \;
fi

echo "[smoke] Test run finished with exit code: ${testExit}"
exit "${testExit}"
