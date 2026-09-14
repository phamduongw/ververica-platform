# Ververica Platform 3.1.3 — OpenShift LAB Baseline Runbook

**Profile:** OpenShift, vendor chart 3.1.3 nguyên bản, PostgreSQL/S3 external, private registry, single-user bootstrap, project-wide node selector `workload.ververica.io/pool=lab`, public Route `http://vvp-vvp-system.apps.ocp.bnh.vn`.

> Đây là baseline OpenShift riêng. **Không dùng `patch-vvp-scheduling-lab.py`** trong profile này. Scheduling được OpenShift admission inject từ annotation của Namespace vào mọi Pod tạo trong `vvp-system` và `vvp-deploy`.

## Nguồn chuẩn đã đối chiếu

Runbook này được khóa theo **Ververica Platform 3.1.3** và package lab đã audit:

- `ververica-platform-3.1.3.tgz` SHA256: `00d1d472b26ebe85c09b9d2416b7372d74728af2c1bfbe12d37fba1309a6ed96`.
- Ververica — Getting Started: Self-managed v3.x: https://docs.ververica.com/docs/vvp3/getting-started
- Ververica — VVP 3.1.3 release notes: https://docs.ververica.com/docs/vvp3/release-notes/vvp-313
- Ververica — PostgreSQL as Metadata Store: https://docs.ververica.com/docs/vvp3/user-guides/admin-operator-guide/postgresql-metadata-store
- Ververica — Platform-Wide Deployment Defaults: https://docs.ververica.com/docs/vvp3/user-guides/admin-operator-guide/manage-configuration-settings/platform-deployment-defaults
- Ververica — Private Image Registry: https://docs.ververica.com/docs/vvp3/user-guides/admin-operator-guide/private-image-registry
- Ververica — Blob Storage: https://docs.ververica.com/docs/vvp3/user-guides/admin-operator-guide/blob-storage

Các điểm mà runbook dựa trực tiếp vào source chart 3.1.3: `global.security.openshift`, `global.rbac.additionalNamespaces`, `vvp-appmanager.flinkVersionMetas`, `globalDeploymentDefaults`, `globalSessionClusterDefaults`, `vvp-console-ui.ui.resources`, và template `vvp-license-fingerprint`. Không copy key legacy từ VVP 2.x.
- Red Hat OpenShift — Project-wide node selectors: https://docs.redhat.com/en/documentation/openshift_container_platform/4.15/html/nodes/controlling-pod-placement-onto-nodes-scheduling



> **Không chạy đồng thời hai profile K8s và OpenShift này vào cùng bộ metadata DB/bucket.** Official Ververica khuyến nghị metadata database dành cho một VVP installation; mỗi installation cũng phải có installation token/license riêng. Hai runbook là hai phương án triển khai độc lập.

## 1. Kiến trúc và các quyết định baseline

- Platform namespace: `vvp-system`.
- Flink runtime namespace: `vvp-deploy`.
- Cả hai Namespace có `openshift.io/node-selector: workload.ververica.io/pool=lab`.
- **Không set `global.security.openshift` trong baseline live-Helm này.** Exact chart 3.1.3 mặc định `false`, nhưng khi `helm install/upgrade` kết nối trực tiếp OpenShift, helper `common.isOpenShift` tự phát hiện API `security.openshift.io/v1` và tự render OpenShift-safe security contexts (bỏ fixed UID/GID/fsGroup để SCC cấp UID theo namespace). Chỉ set `global.security.openshift: true` khi render **offline/GitOps** như `helm template`, ArgoCD hoặc Flux mà `.Capabilities.APIVersions` không phản ánh cluster đích.
- Không tạo SCC custom, không grant `anyuid`, không grant `privileged` cho baseline.
- Không lặp `nodeSelector` trong `globalDeploymentDefaults` / `globalSessionClusterDefaults`; project selector đã áp cho mọi Pod trong `vvp-deploy`. Việc lặp cùng key là thừa và một giá trị khác sẽ conflict/reject ở admission.
- PostgreSQL external, S3 external, private registry và Java/streaming policy giống profile Kubernetes.
- Public endpoint giữ trong `api-gateway.publicApiEndpoint` để sẵn sàng cho OIDC/Keycloak sau này.
- `global.rbac.additionalNamespaces` chỉ để `vvp-deploy`: exact root values 3.1.3 mặc định như vậy và chart tạo RBAC cho release namespace `vvp-system` riêng.
- `single-user.enabled: true` được pin tường minh; không dựa vào mô tả/default chung của tài liệu vì exact package được audit có default `false`.

### Vì sao không cần post-renderer trên OpenShift

Red Hat xác nhận: khi Namespace có `openshift.io/node-selector`, OpenShift **thêm selector đó vào Pod lúc Pod được tạo** và chỉ schedule lên node có label phù hợp. Do đó `helm template` có thể vẫn thấy `spec.template.spec.nodeSelector: null` trên Deployment/StatefulSet; đó **không phải lỗi**. Gate thật là Pod live sau admission.

Vanilla Kubernetes không có admission behavior này, nên profile Kubernetes vẫn cần post-renderer.

> **Nếu chuyển profile OpenShift này sang ArgoCD/Flux:** thêm `global.security.openshift: true`, vì chart 3.1.3 ghi rõ `.Capabilities.APIVersions` chỉ đáng tin khi Helm kết nối live cluster. Đây là override cho offline/GitOps rendering, không phải baseline của runbook live-Helm này.

## 2. Preflight

```bash
oc config current-context
oc version
helm version --short
oc get nodes -o wide
oc get sc thin-csi
oc get scc restricted-v2
oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}{"\n"}'
yq --version
jq --version
```

VVP 3.1.3 release notes có fix cho operator-managed deployments trên OpenShift; 3.1.2 có known issue OpenShift nên profile này khóa ở **3.1.3**.

Kiểm tra DiskPressure:

```bash
oc get nodes -o custom-columns='NAME:.metadata.name,DISK:.status.conditions[?(@.type=="DiskPressure")].status,EPHEMERAL:.status.allocatable.ephemeral-storage'
```

## 3. Label OpenShift worker pool

Chọn đúng worker OpenShift dành cho VVP rồi label. Không reuse hostname K8s nếu không trùng thật:

```bash
oc get nodes -l node-role.kubernetes.io/worker -o wide
oc label node <worker-01> <worker-02> workload.ververica.io/pool=lab --overwrite
oc get nodes -L workload.ververica.io/pool
```

Nếu dùng MachineSet, nên gắn label tại MachineSet/provisioning layer để node replacement kế thừa label.

## 4. Bootstrap OpenShift resources

### `00-namespaces.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vvp-system
  annotations:
    openshift.io/node-selector: "workload.ververica.io/pool=lab"
---
apiVersion: v1
kind: Namespace
metadata:
  name: vvp-deploy
  annotations:
    openshift.io/node-selector: "workload.ververica.io/pool=lab"
```

**Phải tạo Namespace có annotation trước khi tạo Pod VVP.** Annotation này chỉ được admission áp khi Pod được tạo.

### `01-registry-secrets.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: registry-common
  namespace: vvp-system
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {"auths":{"registry.bnh.vn":{"username":"admin","password":"oracle_4U","auth":"YWRtaW46b3JhY2xlXzRV"}}}
---
apiVersion: v1
kind: Secret
metadata:
  name: registry-common
  namespace: vvp-deploy
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: |
    {"auths":{"registry.bnh.vn":{"username":"admin","password":"oracle_4U","auth":"YWRtaW46b3JhY2xlXzRV"}}}
```

Apply:

```bash
oc apply -f 00-namespaces.yaml
oc apply -f 01-registry-secrets.yaml
oc get ns vvp-system vvp-deploy -o jsonpath='{range .items[*]}{.metadata.name}{" => "}{.metadata.annotations.openshift\.io/node-selector}{"\n"}{end}'
oc get secret registry-common -n vvp-system
oc get secret registry-common -n vvp-deploy
```

Expected:

```text
vvp-system => workload.ververica.io/pool=lab
vvp-deploy => workload.ververica.io/pool=lab
```

## 5. PostgreSQL provisioning

Exact chart mặc định `global.k8sOperator.enabled=false`; baseline tạo 7 DB. Nếu sau này bật operator, tạo `vvp-k8soperator`.

### `10-postgresql-provision.sql`

```sql
\set ON_ERROR_STOP on

CREATE ROLE vvp LOGIN PASSWORD 'oracle_4U';

CREATE DATABASE "vvp-appmanager" OWNER vvp;
CREATE DATABASE "vvp-autopilot" OWNER vvp;
CREATE DATABASE "vvp-meta" OWNER vvp;
CREATE DATABASE "vvp-gateway" OWNER vvp;
CREATE DATABASE "vvp-advisor" OWNER vvp;
CREATE DATABASE "vvp-premise" OWNER vvp;
CREATE DATABASE "accesscontrol" OWNER vvp;

-- Only if global.k8sOperator.enabled=true later:
-- CREATE DATABASE "vvp-k8soperator" OWNER vvp;
```

Test:

```bash
export PGPASSWORD='oracle_4U'
for db in vvp-appmanager vvp-autopilot vvp-meta vvp-gateway vvp-advisor vvp-premise accesscontrol; do
  psql -X -v ON_ERROR_STOP=1 -h docker.bnh.vn -p 5432 -U vvp -d "$db" -Atc 'select 1;' \
    && echo "$db OK" || exit 1
done
unset PGPASSWORD
```

## 6. Base Helm values — chưa có license

Baseline này dùng Helm kết nối trực tiếp OpenShift nên **không override `global.security.openshift`**: để chart tự detect cluster là sạch nhất. Khi kiểm tra bằng `helm template` offline, runbook truyền `--api-versions security.openshift.io/v1` thay vì ghi một giá trị thừa vào production values.

Thứ tự giữ theo **relative order của các key khai báo trong root `values.yaml` 3.1.3**: `database` → `rbac` → `authentication` → `image` → `imagePullSecretName`. `blobStorage` và `global.vvp.license` là các key được template/subchart và tài liệu official sử dụng nhưng không có block mặc định trong root `values.yaml`; baseline đặt chúng sau nhóm registry, trước top-level subchart overrides.

### `30-values-vvp.yaml`

```yaml
global:
  database:
    host: "docker.bnh.vn"
    port: 5432
    user: vvp
    password: "oracle_4U"
    provider: postgresql
    createIfMissing: false

  rbac:
    additionalNamespaces:
      - vvp-deploy

  authentication:
    single-user:
      enabled: true

  image:
    registry: "registry.bnh.vn/registry.ververica.cloud"

  imagePullSecretName: registry-common

  blobStorage:
    baseUri: "s3i://vvp"
    s3:
      endpoint: "http://docker.bnh.vn:9000"
      accessKeyId: "admin"
      secretAccessKey: "oracle_4U"

  # ---------------------------------------------------------------------------
  # PHASE 2 - LICENSE (INTENTIONALLY ABSENT DURING PHASE 1 BOOTSTRAP)
  #
  # Phase 1: keep this block COMMENTED. Install VVP first, then retrieve:
  #   Your installation token is: <token>
  # from vvp-appmanager-0 and request a license generated for THIS token.
  #
  # The runbook uses 31-values-license.yaml as a separate overlay. If you prefer
  # one values file, paste the vendor-provided block at THIS exact path under
  # global, preserving the payload verbatim:
  #
  # vvp:
  #   license:
  #     data:
  #       kind: License
  #       apiVersion: v1
  #       metadata:
  #         ...
  #       spec:
  #         ...
  #
  # Do not put a placeholder/old-cluster license here during Phase 1.

api-gateway:
  publicApiEndpoint: "http://vvp-vvp-system.apps.ocp.bnh.vn"

vvp-gateway:
  resources:
    limits:
      cpu: "1"
      memory: "3.5Gi"
    requests:
      cpu: "0.25"
      memory: "1Gi"

vvp-appmanager:
  flinkVersionMetas:
    jdk11:
      installByDefault: false
    jdk17:
      installByDefault: true

  resources:
    limits:
      cpu: "1"
      memory: "3.5Gi"
    requests:
      cpu: "0.5"
      memory: "3Gi"

  globalDeploymentDefaults:
    numberOfTaskSlots: 1
    flinkConfiguration:
      execution.checkpointing.interval: "10s"
      web.cancel.enable: "false"

  globalSessionClusterDefaults: |-
    spec:
      flinkConfiguration:
        taskmanager.numberOfTaskSlots: "1"
        web.cancel.enable: "false"

vvp-appagent:
  persistentVolume:
    size: 40Gi
    storageClass: thin-csi

  appAgentResources:
    limits:
      cpu: "1"
      memory: "1Gi"
    requests:
      cpu: "0.25"
      memory: "1Gi"

  sqlServiceResources:
    limits:
      cpu: "1"
      memory: "3.5Gi"
    requests:
      cpu: "0.5"
      memory: "2.5Gi"

vvp-autopilot:
  resources:
    limits:
      cpu: "1"
      memory: "1Gi"
    requests:
      cpu: "0.25"
      memory: "1Gi"

vvp-meta:
  resources:
    limits:
      cpu: "1"
      memory: "1Gi"
    requests:
      cpu: "0.25"
      memory: "1Gi"

vvp-advisor:
  resources:
    limits:
      cpu: "1"
      memory: "1Gi"
    requests:
      cpu: "0.25"
      memory: "1Gi"

vvp-console-ui:
  ui:
    resources:
      limits:
        cpu: "1"
        memory: "128Mi"
      requests:
        cpu: "0.5"
        memory: "128Mi"
```

### `31-values-license.yaml.example`

```yaml
# Do not apply this example as-is.
# Replace {} with the complete `data` object supplied by Ververica for THIS installation token.
global:
  vvp:
    license:
      data: {}
```

## 7. Render gate trước bootstrap

Không dùng post-renderer:

```bash
helm template ververica-platform \
  ./ververica-platform-3.1.3.tgz \
  --namespace vvp-system \
  --values 30-values-vvp.yaml \
  --api-versions security.openshift.io/v1 \
  > /tmp/vvp-openshift-bootstrap-rendered.yaml
```

Gate 1 — external PostgreSQL:

```bash
if grep -nE 'pg-init|platform-images/postgresql' /tmp/vvp-openshift-bootstrap-rendered.yaml; then
  echo 'FAIL: unexpected PostgreSQL init container' >&2; exit 1
else
  echo 'PASS: external PostgreSQL mode'
fi
```

Gate 2 — OpenShift-safe security context. Command `helm template` ở trên giả lập capability `security.openshift.io/v1`; xuất Pod/container security contexts để xác nhận chart đã tự chọn OpenShift mode mà **không cần** ghi `global.security.openshift: true` vào baseline values:

```bash
yq e '
  select(.kind == "Deployment" or .kind == "StatefulSet") |
  {
    "kind": .kind,
    "name": .metadata.name,
    "podSecurityContext": .spec.template.spec.securityContext,
    "containerSecurityContexts": [.spec.template.spec.containers[].securityContext]
  }
' /tmp/vvp-openshift-bootstrap-rendered.yaml
```

Trong các PodSpec platform, không được pin `runAsUser: 10999`, `runAsGroup: 10999` hoặc `fsGroup: 10999`. `runAsNonRoot`, `seccompProfile`, `allowPrivilegeEscalation: false` và `capabilities.drop: [ALL]` là expected.

Gate 3 — `nodeSelector: null` ở rendered Deployment/StatefulSet **được phép** trong profile này; OpenShift inject vào Pod live sau admission. Không thêm post-renderer chỉ để làm render đẹp hơn.

## 8. Initial Helm install — bootstrap chưa có license

```bash
helm install ververica-platform \
  ./ververica-platform-3.1.3.tgz \
  --namespace vvp-system \
  --values 30-values-vvp.yaml
```

Không `--wait`/`--atomic` ở bootstrap chưa license.

Kiểm tra Pod live đã được OpenShift inject selector:

```bash
oc get pods -n vvp-system -o json | jq -r '.items[] | "\(.metadata.name) node=\(.spec.nodeName // "-") selector=\(.spec.nodeSelector // {})"'
```

Mọi Pod mới phải có:

```text
{"workload.ververica.io/pool":"lab"}
```

Check SCC đang dùng:

```bash
oc get pods -n vvp-system -o json | jq -r '.items[] | "\(.metadata.name) scc=\(.metadata.annotations["openshift.io/scc"] // "-")"'
```

Baseline mong đợi `restricted-v2` (hoặc SCC restricted hợp lệ theo cluster policy), không yêu cầu `anyuid`.

## Quy trình license chuẩn cho bootstrap mới

Baseline **không chứa license**. Đây là chủ đích, vì mỗi installation có fingerprint/token riêng. Official VVP flow là: cài lần đầu → đọc `Your installation token is:` từ AppManager → xin license cho đúng token → chạy `helm upgrade` để áp license. Core pod chưa Ready trước khi có license là trạng thái dự kiến của bootstrap.

Exact chart 3.1.3 có thêm một chi tiết quan trọng: khi bootstrap không có inline license, service có thể tự tạo `vvp-license-fingerprint`. Khi upgrade sang inline license, Helm sẽ từ chối một Secret đã tồn tại nhưng không có Helm ownership. Template 3.1.3 ghi rõ installer phải **adopt** Secret này trước `helm upgrade`; Secret cũng có `helm.sh/resource-policy: keep` để bảo toàn fingerprint. Vì vậy runbook luôn chạy `prepare-vvp-license-upgrade.sh` trước lần activation và trước các lần thay license sau này. Script chỉ kiểm tra token và bổ sung ownership metadata; **không sửa fingerprint**.

### Lấy installation token

```bash
oc logs -n vvp-system vvp-appmanager-0 --tail=-1 | grep -A1 'Your installation token is:'
mkdir -p .work
oc logs -n vvp-system vvp-appmanager-0 --tail=-1 \
  | awk '/Your installation token is:/{getline; print; exit}' \
  > .work/installation-token.txt
chmod 600 .work/installation-token.txt
cat .work/installation-token.txt
```

Lưu token này. Gửi cho Ververica để nhận license dành riêng cho installation đó. Không dùng license của cụm khác.

### Tạo `31-values-license.yaml`

Copy file example rồi thay `{}` bằng **toàn bộ object `data`** Ververica cấp:

```bash
cp 31-values-license.yaml.example 31-values-license.yaml
chmod 600 31-values-license.yaml
```

Cấu trúc phải là:

```yaml
global:
  vvp:
    license:
      data:
        kind: License
        apiVersion: v1
        metadata:
          # vendor payload - giữ nguyên
        spec:
          # vendor payload - giữ nguyên
```

Không tự sửa `token`, `licenseSpec`, `signature`, `licenseId`, `licensedTo` hoặc `expires`.


### File `prepare-vvp-license-upgrade.sh`

Helper này là runbook helper cho exact chart 3.1.3, không phải một binary của Ververica. Nó kiểm tra `licenseSpec == spec`, token license khớp installation token/fingerprint, kiểm tra không có fingerprint Secret trùng label, rồi mới bổ sung Helm ownership metadata nếu Secret đã tồn tại. Nó **không sửa `.data.fingerprint`** và không thể tự kiểm chứng chữ ký cryptographic; VVP validator thực hiện bước đó khi khởi động.

```bash
#!/usr/bin/env bash
set -euo pipefail
umask 077

CLI="${KUBECTL:-kubectl}"
NAMESPACE="${NAMESPACE:-vvp-system}"
RELEASE="${RELEASE:-ververica-platform}"
SECRET="vvp-license-fingerprint"
LICENSE_FILE="${1:-31-values-license.yaml}"
TOKEN_FILE="${INSTALLATION_TOKEN_FILE:-.work/installation-token.txt}"

for bin in "$CLI" yq jq base64; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: missing command: $bin" >&2; exit 1; }
done
[[ -f "$LICENSE_FILE" ]] || { echo "ERROR: license file not found: $LICENSE_FILE" >&2; exit 1; }

license_token="$(yq -r '.global.vvp.license.data.spec.params.token // ""' "$LICENSE_FILE")"
license_id="$(yq -r '.global.vvp.license.data.spec.licenseId // ""' "$LICENSE_FILE")"
metadata_id="$(yq -r '.global.vvp.license.data.metadata.id // ""' "$LICENSE_FILE")"
license_spec_b64="$(yq -r '.global.vvp.license.data.metadata.annotations.licenseSpec // ""' "$LICENSE_FILE")"
signature_b64="$(yq -r '.global.vvp.license.data.metadata.annotations.signature // ""' "$LICENSE_FILE")"

[[ -n "$license_token" && "$license_token" != "null" ]] || { echo "ERROR: missing license token" >&2; exit 1; }
[[ -n "$license_id" && "$license_id" == "$metadata_id" ]] || { echo "ERROR: metadata.id != spec.licenseId" >&2; exit 1; }
[[ -n "$license_spec_b64" && "$license_spec_b64" != "null" ]] || { echo "ERROR: missing licenseSpec" >&2; exit 1; }
[[ -n "$signature_b64" && "$signature_b64" != "null" ]] || { echo "ERROR: missing signature" >&2; exit 1; }

spec_json="$(yq -o=json '.global.vvp.license.data.spec' "$LICENSE_FILE" | jq -S -c .)"
decoded_spec_json="$(printf '%s' "$license_spec_b64" | base64 -d | jq -S -c .)" || {
  echo "ERROR: licenseSpec is not valid base64 JSON" >&2; exit 1;
}
printf '%s' "$signature_b64" | base64 -d >/dev/null || {
  echo "ERROR: signature is not valid base64" >&2; exit 1;
}
[[ "$spec_json" == "$decoded_spec_json" ]] || {
  echo "ERROR: decoded licenseSpec does not match spec; use the vendor-supplied license unchanged" >&2; exit 1;
}

cluster_token=""
if "$CLI" get secret "$SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  cluster_token="$("$CLI" get secret "$SECRET" -n "$NAMESPACE" -o jsonpath='{.data.fingerprint}' | base64 -d)"
else
  if [[ -n "${INSTALLATION_TOKEN:-}" ]]; then
    cluster_token="$INSTALLATION_TOKEN"
  elif [[ -s "$TOKEN_FILE" ]]; then
    cluster_token="$(tr -d '\r\n' < "$TOKEN_FILE")"
  else
    echo "ERROR: $SECRET does not exist and no saved installation token was provided." >&2
    echo "Set INSTALLATION_TOKEN or save it in $TOKEN_FILE before proceeding." >&2
    exit 1
  fi
fi

[[ "$license_token" == "$cluster_token" ]] || {
  echo "ERROR: license token does not match this installation fingerprint/token" >&2
  echo "license: $license_token" >&2
  echo "cluster: $cluster_token" >&2
  exit 1
}

echo "PASS: licenseSpec == spec"
echo "PASS: license token matches this installation"
echo "License ID: $license_id"

label_matches="$("$CLI" get secrets -n "$NAMESPACE" -l name=vvp-license-fingerprint -o json | jq -r '.items | length')"
if (( label_matches > 1 )); then
  echo "ERROR: more than one Secret has label name=vvp-license-fingerprint" >&2
  exit 1
fi
if (( label_matches == 1 )); then
  labeled_name="$("$CLI" get secrets -n "$NAMESPACE" -l name=vvp-license-fingerprint -o json | jq -r '.items[0].metadata.name')"
  [[ "$labeled_name" == "$SECRET" ]] || {
    echo "ERROR: label name=vvp-license-fingerprint belongs to unexpected Secret '$labeled_name'" >&2; exit 1;
  }
fi

if ! "$CLI" get secret "$SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "PASS: fingerprint Secret is absent; no Helm adoption is required."
  echo "Helm 3.1.3 will render the Secret from the inline license token."
  exit 0
fi

owner_release="$("$CLI" get secret "$SECRET" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || true)"
owner_namespace="$("$CLI" get secret "$SECRET" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || true)"
manager="$("$CLI" get secret "$SECRET" -n "$NAMESPACE" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"

[[ -z "$owner_release" || "$owner_release" == "$RELEASE" ]] || {
  echo "ERROR: Secret belongs to Helm release '$owner_release', expected '$RELEASE'" >&2; exit 1;
}
[[ -z "$owner_namespace" || "$owner_namespace" == "$NAMESPACE" ]] || {
  echo "ERROR: Secret belongs to Helm namespace '$owner_namespace', expected '$NAMESPACE'" >&2; exit 1;
}
[[ -z "$manager" || "$manager" == "Helm" ]] || {
  echo "ERROR: Secret managed-by='$manager'; inspect ownership before adoption" >&2; exit 1;
}

mkdir -p backups
"$CLI" get secret "$SECRET" -n "$NAMESPACE" -o yaml > "backups/${SECRET}-$(date -u +%Y%m%dT%H%M%SZ).yaml"
chmod 600 backups/${SECRET}-*.yaml 2>/dev/null || true

"$CLI" label secret "$SECRET" -n "$NAMESPACE" \
  name=vvp-license-fingerprint \
  app.kubernetes.io/managed-by=Helm \
  --overwrite

"$CLI" annotate secret "$SECRET" -n "$NAMESPACE" \
  meta.helm.sh/release-name="$RELEASE" \
  meta.helm.sh/release-namespace="$NAMESPACE" \
  --overwrite

echo "PASS: fingerprint Secret adopted by Helm release $RELEASE/$NAMESPACE; data was not changed"
```
Chạy với `oc`:

```bash
chmod +x prepare-vvp-license-upgrade.sh
KUBECTL=oc ./prepare-vvp-license-upgrade.sh 31-values-license.yaml
```

## 9. Apply license

Render:

```bash
helm template ververica-platform \
  ./ververica-platform-3.1.3.tgz \
  -n vvp-system \
  -f 30-values-vvp.yaml \
  -f 31-values-license.yaml \
  --api-versions security.openshift.io/v1 \
  > /tmp/vvp-openshift-license-rendered.yaml
```

Upgrade lần activation đầu:

```bash
helm upgrade ververica-platform \
  ./ververica-platform-3.1.3.tgz \
  -n vvp-system \
  -f 30-values-vvp.yaml \
  -f 31-values-license.yaml
```

Không dùng post-renderer. Không dùng `--atomic` trong lần activation đầu. Theo dõi:

```bash
oc get pods -n vvp-system -w
oc rollout status sts/vvp-appmanager -n vvp-system --timeout=300s
oc rollout status sts/vvp-gateway -n vvp-system --timeout=300s
```

## 10. Verify license chain

```bash
LICENSE_TOKEN=$(yq -r '.global.vvp.license.data.spec.params.token' 31-values-license.yaml)
SPEC_TOKEN=$(yq -r '.global.vvp.license.data.metadata.annotations.licenseSpec' 31-values-license.yaml | base64 -d | jq -r '.params.token')
FINGERPRINT=$(oc get secret vvp-license-fingerprint -n vvp-system -o jsonpath='{.data.fingerprint}' | base64 -d)
printf 'values      : %s\nlicenseSpec : %s\nfingerprint : %s\n' "$LICENSE_TOKEN" "$SPEC_TOKEN" "$FINGERPRINT"
[ "$LICENSE_TOKEN" = "$SPEC_TOKEN" ] && [ "$SPEC_TOKEN" = "$FINGERPRINT" ]
```

Live mounted license:

```bash
oc exec -n vvp-system vvp-appmanager-0 -- cat /vvp/etc/application-license.yaml > /tmp/appmanager-license.yaml
oc exec -n vvp-system vvp-gateway-0 -- cat /vvp/etc/application-license.yaml > /tmp/gateway-license.yaml
```

## 11. Expose bằng OpenShift Route — HTTP, không TLS

### `40-vvp-route.yaml`

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: vvp
  namespace: vvp-system
spec:
  host: vvp-vvp-system.apps.ocp.bnh.vn
  to:
    kind: Service
    name: api-gateway
  port:
    targetPort: http-alt
```

`http-alt` là tên port của Service `api-gateway` trong exact chart 3.1.3.

```bash
oc apply -f 40-vvp-route.yaml
oc get route vvp -n vvp-system
oc get route vvp -n vvp-system -o jsonpath='{.spec.host}{"\n"}'
curl -v http://vvp-vvp-system.apps.ocp.bnh.vn/
```

## 12. Verify scheduling cho cả platform và Flink runtime

Control-plane:

```bash
oc get pods -n vvp-system -o json | jq -r '.items[] | "\(.metadata.name) node=\(.spec.nodeName) selector=\(.spec.nodeSelector // {})"'
```

Sau khi tạo deployment/session cluster, runtime:

```bash
oc get pods -n vvp-deploy -o json | jq -r '.items[] | "\(.metadata.name) node=\(.spec.nodeName) selector=\(.spec.nodeSelector // {})"'
```

Cả hai namespace phải có selector `workload.ververica.io/pool=lab` do admission inject. Nếu một Pod khai báo cùng key với value khác, OpenShift sẽ reject conflict — đó là behavior mong đợi, không cần thêm patch.

## 13. Quy tắc upgrade về sau

Mọi Helm upgrade sau activation dùng cả hai file:

```text
-f 30-values-vvp.yaml
-f 31-values-license.yaml
```

**Không** thêm `--post-renderer ./patch-vvp-scheduling-lab.py`. Trước mỗi đổi/renew license, chạy `KUBECTL=oc ./prepare-vvp-license-upgrade.sh 31-values-license.yaml`. Khi platform đã healthy, upgrade cấu hình thường có thể thêm `--wait --timeout 10m --atomic`.

## 14. Cleanup / anti-patterns

Không đưa các mục sau vào baseline OpenShift:

- `patch-vvp-scheduling-lab.py`.
- `global.nodeSelector` / `global.affinity` customer fork.
- runtime `kubernetes.pods.nodeSelector` trùng với project selector.
- custom SCC, `anyuid`, `privileged` nếu `restricted-v2` đã admit workload.
- fixed UID/GID/fsGroup override. Với live Helm, để chart tự detect OpenShift; `global.security.openshift: true` chỉ là override cần thiết cho offline/GitOps rendering.
- Ingress khi đang dùng native Route.
- custom metrics 9249, `batchSpec`, `systemDeploymentDefaults`, `systemSessionClusterDefaults`, application `fs.s3a.*`.
- xóa fingerprint Secret để reset license.
