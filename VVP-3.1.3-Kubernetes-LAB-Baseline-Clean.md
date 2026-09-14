# Ververica Platform 3.1.3 — Kubernetes LAB Baseline Runbook

**Profile:** vanilla Kubernetes, vendor chart 3.1.3 nguyên bản, PostgreSQL/S3 external, private registry, single-user bootstrap, Flink runtime ở `vvp-deploy`, scheduling pool `workload.ververica.io/pool=lab`, public endpoint `http://vvp.apps.k8s.bnh.vn`.

> Đây là baseline sạch. Không dùng customer fork `common.podScheduling`, không dùng `global.nodeSelector` cho control-plane vì package vendor 3.1.3 đã được render và field này **không được consume**. Không dùng OpenShift namespace annotation trên vanilla Kubernetes.

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


> **Không chạy đồng thời hai profile K8s và OpenShift này vào cùng bộ metadata DB/bucket.** Official Ververica khuyến nghị metadata database dành cho một VVP installation; mỗi installation cũng phải có installation token/license riêng. Hai runbook là hai phương án triển khai độc lập.

## 1. Kiến trúc và các quyết định baseline

- Platform namespace: `vvp-system`.
- Flink runtime namespace: `vvp-deploy`.
- PostgreSQL external: `docker.bnh.vn:5432`, provider `postgresql`, `createIfMissing=false`.
- S3-compatible external: `s3i://vvp`, endpoint `http://docker.bnh.vn:9000`.
- Registry prefix: `registry.bnh.vn/registry.ververica.cloud`; repository của chart đã chứa `platform-images/...`, vì vậy **không** thêm `/platform-images` vào `global.image.registry`.
- Pull Secret `registry-common` phải có ở cả `vvp-system` và `vvp-deploy`.
- Java policy: JDK11 không seed, JDK17 seed.
- Streaming-only baseline; không khai báo `batchSpec`.
- Không override `systemDeploymentDefaults` / `systemSessionClusterDefaults`.
- Không thêm metrics port 9249 hoặc S3 application `fs.s3a.*` vào global Flink defaults.
- `api-gateway.publicApiEndpoint` được giữ đúng external URL để callback OIDC/Keycloak sau này không dùng URL mặc định của chart.
- `global.rbac.additionalNamespaces` chỉ để `vvp-deploy`: exact root values 3.1.3 mặc định như vậy và chart tạo RBAC cho release namespace `vvp-system` riêng.
- `single-user.enabled: true` được pin tường minh; không dựa vào mô tả/default chung của tài liệu vì exact package được audit có default `false`.

### Scheduling

Vanilla Kubernetes không có project/namespace admission selector tương đương OpenShift. Exact vendor chart 3.1.3 render `nodeSelector: null` trên control-plane nếu chỉ thêm `global.nodeSelector`. Vì vậy:

- **Control-plane VVP**: dùng `patch-vvp-scheduling-lab.py` làm Helm post-renderer trên **mọi install/upgrade**.
- **Flink JobManager/TaskManager**: dùng `vvp-appmanager.globalDeploymentDefaults` và `globalSessionClusterDefaults` với `kubernetes.pods.nodeSelector`.

Không dùng customer fork và post-renderer đồng thời.

## 2. Preflight

```bash
kubectl config current-context
kubectl version
helm version --short
kubectl get nodes -o wide
kubectl get sc vsphere-rwo
kubectl get gateway -A
yq --version
jq --version
python3 -c 'import yaml; print(yaml.__version__)'
```

VVP 3.x official support matrix hiện nêu Kubernetes 1.24–1.34 và Helm 3. PostgreSQL phải là 15+. Kiểm tra DiskPressure và ephemeral storage trước khi kéo image:

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,DISK:.status.conditions[?(@.type=="DiskPressure")].status,EPHEMERAL:.status.allocatable.ephemeral-storage'
```

## 3. Label worker pool

LAB hiện dùng hai worker:

```bash
kubectl label node wk-01.k8s.bnh.vn wk-02.k8s.bnh.vn \
  workload.ververica.io/pool=lab --overwrite

kubectl get nodes -L workload.ververica.io/pool
```

`wk-03` không được mang label này nếu muốn loại khỏi pool.

## 4. Bootstrap Kubernetes resources

### `00-namespaces.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vvp-system
---
apiVersion: v1
kind: Namespace
metadata:
  name: vvp-deploy
```

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
kubectl apply -f 00-namespaces.yaml
kubectl apply -f 01-registry-secrets.yaml
kubectl get secret registry-common -n vvp-system
kubectl get secret registry-common -n vvp-deploy
```

## 5. PostgreSQL provisioning

Official VVP PostgreSQL guide liệt kê 8 DB khi Kubernetes Operator được dùng. Exact chart 3.1.3 mặc định `global.k8sOperator.enabled=false`, nên baseline này chỉ cần 7 DB. Nếu sau này bật operator, tạo thêm `vvp-k8soperator` trước.

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

Chỉ chạy file trên cho **instance mới chưa có role/DB**. Không chạy lại mù quáng trên metadata store đã có dữ liệu. Sau đó test:

```bash
export PGPASSWORD='oracle_4U'
for db in vvp-appmanager vvp-autopilot vvp-meta vvp-gateway vvp-advisor vvp-premise accesscontrol; do
  psql -X -v ON_ERROR_STOP=1 -h docker.bnh.vn -p 5432 -U vvp -d "$db" -Atc 'select 1;' \
    && echo "$db OK" || exit 1
done
unset PGPASSWORD
```

Kiểm tra connection budget bằng DBA; `max_connections=200` là cấu hình LAB đã dùng, không phải minimum chính thức của Ververica:

```sql
SHOW max_connections;
SHOW superuser_reserved_connections;
SELECT datname, usename, state, count(*)
FROM pg_stat_activity
WHERE backend_type='client backend'
GROUP BY datname, usename, state
ORDER BY count(*) DESC;
```

## 6. Base Helm values — chưa có license

Thứ tự được giữ theo **relative order của các key thực sự khai báo trong root `values.yaml` 3.1.3**: `database` → `rbac` → `authentication` → `image` → `imagePullSecretName`. `blobStorage` và `global.vvp.license` là các key được template/subchart và tài liệu official sử dụng nhưng không được khai báo thành block mặc định trong root `values.yaml`; baseline đặt chúng sau nhóm registry, trước các top-level subchart overrides. YAML mapping không có semantics theo thứ tự, nhưng convention này giữ file dễ audit với chart gốc.

`api-gateway` là subchart override bổ sung, đặt ngay sau `global`; sau đó các block VVP giữ thứ tự chart: `vvp-gateway`, `vvp-appmanager`, `vvp-appagent`, `vvp-autopilot`, `vvp-meta`, `vvp-advisor`, `vvp-console-ui`.

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
  publicApiEndpoint: "http://vvp.apps.k8s.bnh.vn"

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
    spec:
      template:
        spec:
          kubernetes:
            pods:
              nodeSelector:
                workload.ververica.io/pool: lab

  globalSessionClusterDefaults: |-
    spec:
      flinkConfiguration:
        taskmanager.numberOfTaskSlots: "1"
        web.cancel.enable: "false"
      kubernetes:
        pods:
          nodeSelector:
            workload.ververica.io/pool: lab

vvp-appagent:
  persistentVolume:
    size: 40Gi
    storageClass: vsphere-rwo

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

## 7. Kubernetes scheduling post-renderer

### `patch-vvp-scheduling-lab.py`

```python
#!/usr/bin/env python3
import sys
import yaml

NODE_SELECTOR = {
    "workload.ververica.io/pool": "lab"
}

def patch_pod_spec(pod_spec):
    selector = pod_spec.setdefault("nodeSelector", {})
    selector.update(NODE_SELECTOR)

documents = []

for doc in yaml.safe_load_all(sys.stdin):
    if doc is None:
        continue

    kind = doc.get("kind")

    if kind in ("Deployment", "StatefulSet", "DaemonSet", "Job"):
        pod_spec = (
            doc.setdefault("spec", {})
               .setdefault("template", {})
               .setdefault("spec", {})
        )
        patch_pod_spec(pod_spec)

    elif kind == "CronJob":
        pod_spec = (
            doc.setdefault("spec", {})
               .setdefault("jobTemplate", {})
               .setdefault("spec", {})
               .setdefault("template", {})
               .setdefault("spec", {})
        )
        patch_pod_spec(pod_spec)

    elif kind == "Pod":
        patch_pod_spec(doc.setdefault("spec", {}))

    documents.append(doc)

yaml.safe_dump_all(
    documents,
    sys.stdout,
    default_flow_style=False,
    sort_keys=False,
)
```

```bash
chmod +x patch-vvp-scheduling-lab.py
python3 -c 'import yaml'
```

## 8. Render gate trước bootstrap

Render **có post-renderer**:

```bash
helm template ververica-platform \
  ./ververica-platform-3.1.3.tgz \
  --namespace vvp-system \
  --values 30-values-vvp.yaml \
  --post-renderer ./patch-vvp-scheduling-lab.py \
  > /tmp/vvp-bootstrap-rendered.yaml
```

Gate 1 — không được có PG init container/vendor PostgreSQL image vì `createIfMissing=false`:

```bash
if grep -nE 'pg-init|platform-images/postgresql' /tmp/vvp-bootstrap-rendered.yaml; then
  echo 'FAIL: unexpected PostgreSQL init container' >&2; exit 1
else
  echo 'PASS: external PostgreSQL mode'
fi
```

Gate 2 — mọi Deployment/StatefulSet phải có selector LAB sau post-renderer:

```bash
yq e 'select(.kind == "Deployment" or .kind == "StatefulSet") | {"kind": .kind, "name": .metadata.name, "nodeSelector": .spec.template.spec.nodeSelector}' /tmp/vvp-bootstrap-rendered.yaml
```

Mỗi object phải có:

```yaml
nodeSelector:
  workload.ververica.io/pool: lab
```

Gate 3 — kiểm tra image prefix:

```bash
grep -oE 'image: .*registry.bnh.vn/registry.ververica.cloud[^ ]*' /tmp/vvp-bootstrap-rendered.yaml | sort -u
```

Không được có `.../platform-images/platform-images/...`.

## 9. Initial Helm install — bootstrap chưa có license

Official flow cho phép core pod chưa Ready trong giai đoạn này, nên **không dùng `--wait` hoặc `--atomic`** ở bước bootstrap.

```bash
helm install ververica-platform \
  ./ververica-platform-3.1.3.tgz \
  --namespace vvp-system \
  --values 30-values-vvp.yaml \
  --post-renderer ./patch-vvp-scheduling-lab.py
```

Kiểm tra:

```bash
helm status ververica-platform -n vvp-system
kubectl get pods -n vvp-system -o wide
```

## Quy trình license chuẩn cho bootstrap mới

Baseline **không chứa license**. Đây là chủ đích, vì mỗi installation có fingerprint/token riêng. Official VVP flow là: cài lần đầu → đọc `Your installation token is:` từ AppManager → xin license cho đúng token → chạy `helm upgrade` để áp license. Core pod chưa Ready trước khi có license là trạng thái dự kiến của bootstrap.

Exact chart 3.1.3 có thêm một chi tiết quan trọng: khi bootstrap không có inline license, service có thể tự tạo `vvp-license-fingerprint`. Khi upgrade sang inline license, Helm sẽ từ chối một Secret đã tồn tại nhưng không có Helm ownership. Template 3.1.3 ghi rõ installer phải **adopt** Secret này trước `helm upgrade`; Secret cũng có `helm.sh/resource-policy: keep` để bảo toàn fingerprint. Vì vậy runbook luôn chạy `prepare-vvp-license-upgrade.sh` trước lần activation và trước các lần thay license sau này. Script chỉ kiểm tra token và bổ sung ownership metadata; **không sửa fingerprint**.

### Lấy installation token

```bash
kubectl logs -n vvp-system vvp-appmanager-0 --tail=-1 | grep -A1 'Your installation token is:'
mkdir -p .work
kubectl logs -n vvp-system vvp-appmanager-0 --tail=-1 \
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
Chạy:

```bash
chmod +x prepare-vvp-license-upgrade.sh
./prepare-vvp-license-upgrade.sh 31-values-license.yaml
```

Expected: token trong license, decoded `licenseSpec`, và fingerprint Secret phải đồng nhất; nếu Secret chưa có Helm metadata, script bổ sung `app.kubernetes.io/managed-by=Helm` và `meta.helm.sh/release-*`.

## 10. Apply license

Render lại trước upgrade:

```bash
helm template ververica-platform \
  ./ververica-platform-3.1.3.tgz \
  -n vvp-system \
  -f 30-values-vvp.yaml \
  -f 31-values-license.yaml \
  --post-renderer ./patch-vvp-scheduling-lab.py \
  > /tmp/vvp-license-rendered.yaml
```

Lần activation đầu dùng `helm upgrade` **không `--atomic`** để không rollback license/fingerprint trong lúc StatefulSet đang chuyển revision:

```bash
helm upgrade ververica-platform \
  ./ververica-platform-3.1.3.tgz \
  -n vvp-system \
  -f 30-values-vvp.yaml \
  -f 31-values-license.yaml \
  --post-renderer ./patch-vvp-scheduling-lab.py
```

Theo dõi:

```bash
kubectl get pods -n vvp-system -w
```

Sau khi pod lên:

```bash
kubectl rollout status sts/vvp-appmanager -n vvp-system --timeout=300s
kubectl rollout status sts/vvp-gateway -n vvp-system --timeout=300s
```

Nếu StatefulSet đã có `updateRevision` mới nhưng pod vẫn giữ revision cũ và NotReady, **chỉ sau khi kiểm tra license/fingerprint khớp**, xóa pod cũ để StatefulSet tạo lại:

```bash
kubectl get sts vvp-appmanager vvp-gateway -n vvp-system \
  -o custom-columns='NAME:.metadata.name,CURRENT:.status.currentRevision,UPDATE:.status.updateRevision,READY:.status.readyReplicas'
```

## 11. Verify license chain

```bash
LICENSE_TOKEN=$(yq -r '.global.vvp.license.data.spec.params.token' 31-values-license.yaml)
SPEC_TOKEN=$(yq -r '.global.vvp.license.data.metadata.annotations.licenseSpec' 31-values-license.yaml | base64 -d | jq -r '.params.token')
FINGERPRINT=$(kubectl get secret vvp-license-fingerprint -n vvp-system -o jsonpath='{.data.fingerprint}' | base64 -d)
printf 'values      : %s\nlicenseSpec : %s\nfingerprint : %s\n' "$LICENSE_TOKEN" "$SPEC_TOKEN" "$FINGERPRINT"
[ "$LICENSE_TOKEN" = "$SPEC_TOKEN" ] && [ "$SPEC_TOKEN" = "$FINGERPRINT" ]
```

Check live license mounted by both services:

```bash
kubectl exec -n vvp-system vvp-appmanager-0 -- cat /vvp/etc/application-license.yaml > /tmp/appmanager-license.yaml
kubectl exec -n vvp-system vvp-gateway-0 -- cat /vvp/etc/application-license.yaml > /tmp/gateway-license.yaml
yq '.vvp.license.data.spec.licenseId, .vvp.license.data.spec.params.token' /tmp/appmanager-license.yaml
yq '.vvp.license.data.spec.licenseId, .vvp.license.data.spec.params.token' /tmp/gateway-license.yaml
```

## 12. Expose bằng Gateway API

LAB Gateway đã xác nhận: `gateway-system/apps-gateway`, address `192.168.100.50`.

### `40-vvp-httproute.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: vvp
  namespace: vvp-system
spec:
  parentRefs:
    - name: apps-gateway
      namespace: gateway-system
  hostnames:
    - vvp.apps.k8s.bnh.vn
  rules:
    - backendRefs:
        - name: api-gateway
          port: 8080
```

```bash
kubectl apply -f 40-vvp-httproute.yaml
kubectl get httproute vvp -n vvp-system
kubectl describe httproute vvp -n vvp-system
```

Conditions cần có `Accepted=True` và `ResolvedRefs=True`. DNS:

```text
vvp.apps.k8s.bnh.vn -> 192.168.100.50
```

Test trước DNS:

```bash
curl -v -H 'Host: vvp.apps.k8s.bnh.vn' http://192.168.100.50/
```

## 13. Final verification

```bash
kubectl get pods -n vvp-system -o wide
kubectl get deploy,sts -n vvp-system
kubectl get pvc -n vvp-system
kubectl get svc api-gateway -n vvp-system
```

Control-plane selector phải còn sau mọi Helm upgrade:

```bash
kubectl get deploy,sts -n vvp-system -o json | jq -r '.items[] | "\(.kind)/\(.metadata.name)  \(.spec.template.spec.nodeSelector // {})"'
```

Flink runtime policy được kiểm tra khi tạo deployment/session cluster mới:

```bash
kubectl get pods -n vvp-deploy -o wide
kubectl get pods -n vvp-deploy -o json | jq -r '.items[] | "\(.metadata.name)  \(.spec.nodeSelector // {})"'
```

## 14. Quy tắc upgrade về sau

Mọi Helm command trên Kubernetes phải luôn mang:

```text
--values 30-values-vvp.yaml
--values 31-values-license.yaml
--post-renderer ./patch-vvp-scheduling-lab.py
```

Trước khi đổi/renew license: chạy lại `prepare-vvp-license-upgrade.sh`; nếu ownership đã đúng, script no-op nhưng vẫn kiểm tra token/fingerprint. Khi hệ thống đã healthy ổn định, các upgrade cấu hình thông thường có thể dùng `--wait --timeout 10m --atomic`. Không uninstall/reinstall để đổi license.

## 15. Cleanup / anti-patterns

Không đưa các mục sau vào baseline:

- `global.nodeSelector` / `global.affinity` của customer fork.
- OpenShift `openshift.io/node-selector`.
- `global.ingress` khi đã dùng Gateway API.
- custom Prometheus port `9249`.
- `systemDeploymentDefaults` / `systemSessionClusterDefaults`.
- `batchSpec`.
- application-level `fs.s3a.*` credentials.
- `vvp-k8soperator` DB khi operator vẫn tắt.
- xóa `vvp-license-fingerprint` để “reset” license.
- bỏ post-renderer ở một Helm upgrade rồi thêm lại ở lần sau.
