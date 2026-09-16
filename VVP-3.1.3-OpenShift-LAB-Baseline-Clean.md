# VVP 3.1.3 — OpenShift LAB: cài đặt và cấu hình

Các block tạo file bên dưới **ghi đè baseline cùng tên**. Chỉ tạo `30-values-vvp.yaml` trước lần cài đặt ban đầu; sau khi nhận license, sửa file hiện có và không chạy lại block `cat` của file này. Không chạy lại các block tạo file trên cấu hình đã tùy biến. Thực hiện từ thư mục `openshift/`, chart ở `../ververica-platform-3.1.3.tgz`. Hai profile là hai phương án cài đặt; mỗi installation cần license cấp cho đúng installation token của nó.

## 1. Thông số và điều kiện áp dụng

| Hạng mục | Cấu hình LAB |
| --- | --- |
| Release | `ververica-platform` |
| Namespaces | `vvp-system`, `vvp-deploy` |
| Workers | `wk-01.ocp.bnh.vn`, `wk-02.ocp.bnh.vn` |
| StorageClass | `thin-csi` |
| Endpoint | `https://vvp.apps.ocp.bnh.vn` |

Áp dụng cho cluster OpenShift có RBAC, Helm 3 và CLI `oc` có sẵn với quyền cài đặt. PostgreSQL 15.x, S3 và registry phải sẵn sàng, truy cập và xác thực được từ worker; StorageClass và DNS phải phù hợp với bảng LAB. Thực hiện các bước theo thứ tự; chỉ chuyển sang block tiếp theo khi block hiện tại thành công và đạt điều kiện được nêu. Khi thiếu điều kiện hoặc lệnh lỗi, dừng để xử lý nguyên nhân. SQL cần `psql`; helper cần Bash, Mike Farah `yq` v4, `jq`, `base64` có sẵn. Xem [điều kiện vendor](https://docs.ververica.com/docs/vvp3/getting-started).

> **Không triển khai lên target đã ghi nhận:** OpenShift 4.22.12 / Kubernetes 1.35.6 nằm ngoài dải Kubernetes 1.24–1.34 trong [Getting Started](https://docs.ververica.com/docs/vvp3/getting-started). Chỉ dùng target được hỗ trợ; với target 1.35.6 phải có xác nhận hỗ trợ của vendor trước khi triển khai.

Baseline LAB được cấu hình trên [package 3.1.3](ververica-platform-3.1.3.tgz), member `ververica-platform/Chart.yaml` có `version` và `appVersion: 3.1.3`; schema/defaults lấy từ `ververica-platform/values.yaml`. Đây không phải toàn bộ defaults hoặc khuyến nghị production của vendor. Metadata này không chứng minh package byte-identical với bản OCI vendor; các nhận định template chỉ áp dụng package đã đối chiếu. `kubeVersion: >=1.19.0-0` của chart không thay thế support matrix vendor.

## 2. Gán nhãn worker và tạo namespace

Hai worker và label `workload.ververica.io/pool=lab` là lựa chọn LAB. Tạo cả namespace platform và runtime trước install theo [Getting Started](https://docs.ververica.com/docs/vvp3/getting-started); `global.rbac.additionalNamespaces` cấu hình phạm vi RBAC, không tự tạo namespace.

Annotation `openshift.io/node-selector` là [cơ chế OpenShift](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/controlling-pod-placement-onto-nodes-scheduling#nodes-scheduler-node-selectors-project_nodes-scheduler-node-selectors) bổ sung selector cho Pod mới trong namespace, không phải hành vi chart. Nguồn Red Hat 4.18 giải thích cơ chế, không xác nhận VVP hỗ trợ OCP 4.22.

### Tạo `00-namespaces.yaml`

```bash
cat > 00-namespaces.yaml <<'EOF'
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
EOF
```

```bash
oc label node wk-01.ocp.bnh.vn wk-02.ocp.bnh.vn workload.ververica.io/pool=lab --overwrite &&
oc apply -f 00-namespaces.yaml
```

## 3. Tạo Secret truy cập registry

Tạo `registry-common` ở cả `vvp-system` và `vvp-deploy`. [Private Image Registry](https://docs.ververica.com/docs/vvp3/user-guides/admin-operator-guide/private-image-registry) yêu cầu mirror platform, vera, artifact-fetcher và Flink runtime cùng các image phụ thuộc cần dùng, đúng tag của package đang cài. Tag lấy từ chart 3.1.3, không lấy bảng ví dụ 3.1.2. Registry mirror và credentials dưới đây là lựa chọn LAB. Helm render chỉ sinh manifest, không kéo image.

### Tạo `01-registry-secrets.yaml`

```bash
cat > 01-registry-secrets.yaml <<'EOF'
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
EOF
```

```bash
oc apply -f 01-registry-secrets.yaml
```

## 4. Tạo role và database PostgreSQL

`provider: postgresql`, `createIfMissing: false` là override hợp lệ theo [PostgreSQL as Metadata Store](https://docs.ververica.com/docs/vvp3/user-guides/admin-operator-guide/postgresql-metadata-store) và `ververica-platform/values.yaml` trong [package 3.1.3](ververica-platform-3.1.3.tgz); DB phải tồn tại trước install. DBA có `psql` chạy SQL riêng một lần khi role/DB chưa tồn tại; không chạy lại trên metadata có dữ liệu. SQL gồm bảy DB của baseline; DB thứ tám `vvp-k8soperator` chỉ cần khi bật `global.k8sOperator.enabled=true`, mặc định chart là `false`.

### Tạo `10-postgresql-provision.sql`

```bash
cat > 10-postgresql-provision.sql <<'EOF'
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
EOF
```

```bash
read -r -p 'PostgreSQL admin user do DBA cấp: ' PGADMIN &&
test -n "$PGADMIN" &&
psql -X -W -v ON_ERROR_STOP=1 -h docker.bnh.vn -p 5432 \
  -U "$PGADMIN" -d postgres -f 10-postgresql-provision.sql
```

## 5. Tạo Helm values cho platform

Endpoints, DB/S3, registry mirror, credentials, resource requests/limits, JDK17 và Flink deployment/session defaults là lựa chọn LAB được giữ nguyên, không phải sizing tối thiểu hay mặc định vendor. Không suy ra runtime đã hoạt động live từ values hoặc render. PVC `vvp` do `ververica-platform/charts/vvp-appagent/templates/sql-pvc.yaml` trong [package 3.1.3](ververica-platform-3.1.3.tgz) tạo; `40Gi` và `thin-csi` là override LAB. Single-user bootstrap được bật tường minh.

Giữ `global.vvp.license.data: {}` cho lần render/cài đặt ban đầu. Sau khi nhận license, sửa trực tiếp trường này trong cùng file ở bước 7. Khối `vvp` nằm trong `global`, sau `blobStorage` và trước các override subchart. Root `ververica-platform/values.yaml` không khai báo sẵn khối license; đường dẫn `global.vvp.license.data` được template chart sử dụng, không có thứ tự key license bắt buộc trong YAML.

### Tạo `30-values-vvp.yaml`

```bash
cat > 30-values-vvp.yaml <<'EOF'
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

  vvp:
    license:
      data: {}

api-gateway:
  publicApiEndpoint: "https://vvp.apps.ocp.bnh.vn"

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
EOF
```

`common.isOpenShift` trong `ververica-platform/charts/common/templates/_security.tpl` của [package 3.1.3](ververica-platform-3.1.3.tgz) xét API capability `security.openshift.io/v1` **hoặc** `global.security.openshift`. Offline render truyền capability để chọn đúng nhánh, không cần thêm override values. Security helpers bỏ fixed UID/GID/fsGroup trên OpenShift; điều này không xác nhận hỗ trợ phiên bản cluster hoặc bảo đảm mọi runtime workload qua SCC. Profile không tạo custom SCC/`anyuid` và không dùng post-renderer.

## 6. Render manifest và cài đặt ban đầu

Render manifest ra stdout để kiểm tra cấu hình. Lần cài đặt ban đầu không dùng `--wait`/`--atomic`. Theo [Getting Started](https://docs.ververica.com/docs/vvp3/getting-started), một số core Pod chưa Ready trước license là dự kiến; không quy mọi lỗi bootstrap cho thiếu license.

```bash
helm template ververica-platform ../ververica-platform-3.1.3.tgz \
  -n vvp-system -f 30-values-vvp.yaml --include-crds \
  --api-versions security.openshift.io/v1
```

Chỉ chạy lệnh cài đặt dưới đây khi render thành công.

```bash
helm install ververica-platform ../ververica-platform-3.1.3.tgz \
  -n vvp-system -f 30-values-vvp.yaml &&
oc get pods -n vvp-system
```

## 7. Lấy và kích hoạt license ban đầu

Theo [Getting Started](https://docs.ververica.com/docs/vvp3/getting-started), lấy token AppManager, gửi `license_request@ververica.com`, nhận toàn bộ object vendor tại `global.vvp.license.data`, rồi Helm upgrade để hoàn tất installation. License được lưu trực tiếp trong `30-values-vvp.yaml`; helper dưới đây là công cụ LAB. Giữ kín log, token và license.

### Lấy token

Đọc token từ log AppManager của lần cài đặt vừa tạo và lưu vào `.work/installation-token.txt` để helper sử dụng.

```bash
(
  umask 077 &&
  mkdir -p .work &&
  oc logs vvp-appmanager-0 -n vvp-system --tail=-1 > .work/appmanager-bootstrap.log &&
  grep -A2 'Your installation token is:' .work/appmanager-bootstrap.log &&
  read -r -p 'Dán installation token từ log: ' INSTALLATION_TOKEN &&
  test -n "$INSTALLATION_TOKEN" &&
  printf '%s\n' "$INSTALLATION_TOKEN" > .work/installation-token.txt
)
```

### Dừng chờ vendor

Gửi installation token đến `license_request@ververica.com`; dừng tại đây đến khi nhận license cho đúng installation này.

### Thay license trực tiếp trong `30-values-vvp.yaml`

Mở file values đã dùng để cài đặt. Thay `{}` tại `global.vvp.license.data` bằng toàn bộ object license vendor cấp cho installation token vừa gửi; giữ nguyên các cấu hình khác. Không chạy lại block tạo values ở bước 5 vì sẽ ghi đè license. Không dùng `data: {}` để kích hoạt. File này chứa license sau khi sửa; không commit hoặc chia sẻ file values đã điền license.

```bash
chmod 600 30-values-vvp.yaml &&
vi 30-values-vvp.yaml
```

Template `ververica-platform/templates/license-fingerprint-secret.yaml` trong [package 3.1.3](ververica-platform-3.1.3.tgz) render Secret khi có inline token và không có `global.licenseSecret`; helper chạy trước upgrade để tránh conflict ownership với Secret có sẵn. Helper kiểm cấu trúc, base64, spec/token và ownership, backup/adopt khi cần, không sửa fingerprint data. Đây không phải helper vendor và không xác minh chữ ký mật mã.

### Tạo `prepare-vvp-license-upgrade.sh`

```bash
cat > prepare-vvp-license-upgrade.sh <<'EOF' &&
#!/usr/bin/env bash
set -euo pipefail
umask 077

CLI="${KUBECTL:-kubectl}"
NAMESPACE="${NAMESPACE:-vvp-system}"
RELEASE="${RELEASE:-ververica-platform}"
SECRET="vvp-license-fingerprint"
LICENSE_FILE="${1:-30-values-vvp.yaml}"
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

secret_json="$("$CLI" get secret "$SECRET" -n "$NAMESPACE" --ignore-not-found=true -o json)" || {
  echo "ERROR: unable to read fingerprint Secret; refusing license activation" >&2
  exit 1
}
cluster_token=""
if [[ -n "$secret_json" ]]; then
  cluster_token="$(printf '%s' "$secret_json" | jq -er '.data.fingerprint | select(type == "string" and length > 0)' | base64 -d)" || {
    echo "ERROR: fingerprint Secret has invalid JSON, missing fingerprint, or invalid base64" >&2
    exit 1
  }
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
  exit 1
}

echo "PASS: licenseSpec == spec"
echo "PASS: license token matches this installation"
echo "License ID: $license_id"

label_json="$("$CLI" get secrets -n "$NAMESPACE" -l name=vvp-license-fingerprint -o json)" || {
  echo "ERROR: unable to list fingerprint Secrets; refusing license activation" >&2
  exit 1
}
label_matches="$(printf '%s' "$label_json" | jq -er '.items | select(type == "array") | length')" || {
  echo "ERROR: invalid fingerprint Secret list response" >&2
  exit 1
}
if (( label_matches > 1 )); then
  echo "ERROR: more than one Secret has label name=vvp-license-fingerprint" >&2
  exit 1
fi
if (( label_matches == 1 )); then
  labeled_name="$(printf '%s' "$label_json" | jq -er '.items[0].metadata.name')"
  [[ "$labeled_name" == "$SECRET" ]] || {
    echo "ERROR: label name=vvp-license-fingerprint belongs to unexpected Secret '$labeled_name'" >&2; exit 1;
  }
fi

if [[ -z "$secret_json" ]]; then
  echo "PASS: fingerprint Secret is absent; no Helm adoption is required."
  echo "The VVP 3.1.3 chart will render the Secret from the inline license token."
  exit 0
fi

owner_release="$(printf '%s' "$secret_json" | jq -r '.metadata.annotations["meta.helm.sh/release-name"] // ""')"
owner_namespace="$(printf '%s' "$secret_json" | jq -r '.metadata.annotations["meta.helm.sh/release-namespace"] // ""')"
manager="$(printf '%s' "$secret_json" | jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // ""')"

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
printf '%s\n' "$secret_json" > "backups/${SECRET}-$(date -u +%Y%m%dT%H%M%SZ).yaml"

"$CLI" label secret "$SECRET" -n "$NAMESPACE" \
  name=vvp-license-fingerprint \
  app.kubernetes.io/managed-by=Helm \
  --overwrite

"$CLI" annotate secret "$SECRET" -n "$NAMESPACE" \
  meta.helm.sh/release-name="$RELEASE" \
  meta.helm.sh/release-namespace="$NAMESPACE" \
  --overwrite

echo "PASS: fingerprint Secret adopted by Helm release $RELEASE/$NAMESPACE; data was not changed"
EOF
chmod +x prepare-vvp-license-upgrade.sh
```

### Kích hoạt license

Sau Helm upgrade, xóa hai Pod để cưỡng bức restart nhằm nạp license; StatefulSet controller sẽ tạo Pod thay thế. Các lệnh rollout bên dưới chờ hai StatefulSet sẵn sàng.

Chỉ chạy sau khi đã lưu license vendor vào `30-values-vvp.yaml` và tạo helper thành công. Helper phải thành công trước khi Helm cập nhật release; chỉ chuyển sang bước truy cập khi cả hai lệnh rollout hoàn tất. Nếu một lệnh lỗi, dừng tại bước này và xử lý nguyên nhân.

```bash
KUBECTL=oc ./prepare-vvp-license-upgrade.sh 30-values-vvp.yaml &&
helm upgrade ververica-platform ../ververica-platform-3.1.3.tgz \
  -n vvp-system -f 30-values-vvp.yaml &&
oc delete pod vvp-appmanager-0 vvp-gateway-0 -n vvp-system --ignore-not-found=true --wait=true &&
oc rollout status sts/vvp-appmanager -n vvp-system --timeout=300s &&
oc rollout status sts/vvp-gateway -n vvp-system --timeout=300s
```

## 8. Cấu hình truy cập giao diện LAB

Route dùng TLS `edge`: router kết thúc TLS và chuyển tiếp HTTP tới Service; HTTP bên ngoài được chuyển hướng sang HTTPS. Chứng chỉ router phải hợp lệ cho hostname và được client tin cậy. Route là tích hợp hạ tầng LAB ngoài Helm. Service `api-gateway` dùng port name `http-alt`, port từ values là `8080`, theo `ververica-platform/charts/api-gateway/templates/service.yaml` trong [package 3.1.3](ververica-platform-3.1.3.tgz); không dùng port 80 từ ví dụ Ingress của docs.

### Tạo `40-vvp-route.yaml`

```bash
cat > 40-vvp-route.yaml <<'EOF'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: vvp
  namespace: vvp-system
spec:
  host: vvp.apps.ocp.bnh.vn
  to:
    kind: Service
    name: api-gateway
  port:
    targetPort: http-alt
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
```

```bash
oc apply -f 40-vvp-route.yaml &&
oc get route vvp -n vvp-system -o yaml
```

Route cần condition `Admitted=True`; nếu chưa đạt, dừng và liên hệ owner ingress/router.

Chỉ kiểm tra URL khi Route đã được chấp nhận và DNS đúng. HTTP 2xx không chứng minh Flink runtime hoạt động.

```bash
curl --fail --show-error https://vvp.apps.ocp.bnh.vn/
```

## 9. Cấu hình Deployment Target

Mở endpoint trong bảng bằng trình duyệt. Trong UI, theo [Create a Deployment Target](https://docs.ververica.com/docs/vvp3/getting-started#create-a-deployment-target): **Deployment Targets → Create Deployment Target**, nhập **Deployment Target Name** là `lab`, **Kubernetes Namespace** là `vvp-deploy`, chọn **OK**. Nếu target `lab` đã trỏ đúng namespace thì giữ nguyên. Nếu tên đó trỏ namespace khác, dừng; không sửa/xóa target có thể đang được sử dụng. Đây là cấu hình namespace runtime, chưa chứng minh Flink job hoạt động.

## 10. Cleanup VVP

**Chỉ chạy khi muốn gỡ installation LAB.** Xóa hai namespace cùng tài nguyên bên trong và CRD VVP cấp cluster; không chạy nếu installation khác dùng chung namespace/CRD. PostgreSQL/S3/registry external giữ nguyên. Block này không xác nhận xóa volume backend, không gỡ label worker hoặc xóa file local; lỗi Helm bị bỏ qua theo lệnh dưới đây.

```bash
helm uninstall ververica-platform \
  -n vvp-system 2>/dev/null || true

oc delete namespace vvp-system vvp-deploy \
  --ignore-not-found=true \
  --wait=true

while oc get ns vvp-system >/dev/null 2>&1 || \
      oc get ns vvp-deploy >/dev/null 2>&1; do
  echo "Waiting for namespace cleanup..."
  sleep 3
done

oc delete crd \
  vvp3deployments.v3.ververica.platform \
  --ignore-not-found=true
```

Trước khi cài lại, tự đặt `global.vvp.license.data` trong `30-values-vvp.yaml` về `{}` và lấy license cho token mới. Không chạy lại SQL tạo role/DB đã tồn tại; dữ liệu external có thể còn state cũ.

## Nguồn tham chiếu

- [Getting Started: Self-managed v3.x](https://docs.ververica.com/docs/vvp3/getting-started): điều kiện hỗ trợ, namespace/Secret, install/license và Deployment Target. Trang rolling **3.1 (latest)** có ví dụ install 3.1.1; runbook dùng package 3.1.3.
- [PostgreSQL as Metadata Store](https://docs.ververica.com/docs/vvp3/user-guides/admin-operator-guide/postgresql-metadata-store): provider, `createIfMissing` và tạo DB thủ công.
- [Private Image Registry](https://docs.ververica.com/docs/vvp3/user-guides/admin-operator-guide/private-image-registry): mirror và pull Secret; tag ví dụ 3.1.2 không phải baseline 3.1.3.
- [Red Hat OpenShift 4.18 — project node selectors](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/controlling-pod-placement-onto-nodes-scheduling#nodes-scheduler-node-selectors-project_nodes-scheduler-node-selectors): cơ chế namespace annotation, không phải support matrix VVP trên OCP 4.22.
- [package 3.1.3](ververica-platform-3.1.3.tgz): các member dưới prefix `ververica-platform/`: `Chart.yaml`, `values.yaml`, `charts/common/templates/_security.tpl`, `templates/license-fingerprint-secret.yaml`, `charts/api-gateway/templates/service.yaml`, `charts/vvp-appagent/templates/sql-pvc.yaml`.
