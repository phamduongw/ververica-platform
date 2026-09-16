# VVP 3.1.3 — Context bàn giao

## Mục tiêu và quyết định cuối cùng

Repository chứa hai phương án LAB: vanilla Kubernetes và OpenShift. Hai runbook phải cùng flow, nhưng giữ khác biệt CLI, scheduling/security, worker, StorageClass và exposure. Không coi LAB sizing/credential/endpoint là default hoặc production recommendation của vendor.

- Runbook: `VVP-3.1.3-Kubernetes-LAB-Baseline-Clean.md`, `VVP-3.1.3-OpenShift-LAB-Baseline-Clean.md`.
- Thực hiện trong `kubernetes/` hoặc `openshift/`; chart ở một cấp cha.
- Không thêm lại mục chuẩn bị phiên, kubeconfig/version/checksum gates, venv setup, quản trị Git, hoặc upgrade/renew định kỳ.
- Các artifact được trình bày đầy đủ bằng heredoc, mỗi file đúng một heading `### Tạo filename` (tên file có backtick trong runbook). Source và payload phải khớp bytes khi baseline chưa được điền license.
- Helper phải nằm ngay trong bước license, trước activation; không đưa vào phụ lục.

## Flow hiện tại

1. Thông số/điều kiện áp dụng.
2. Worker và namespace.
3. Registry Secret trong cả `vvp-system` và `vvp-deploy`.
4. PostgreSQL provisioning riêng một lần cho role/DB chưa tồn tại.
5. Values; Kubernetes thêm post-renderer ngay tại bước này.
6. Render stdout, sau đó initial install riêng; không `--wait`/`--atomic` cho bootstrap.
7. Token → vendor → sửa license ngay trong values → tạo helper → helper/upgrade/delete Pod/rollout.
8. Exposure.
9. Deployment Target `lab` → `vvp-deploy`.
10. Cleanup ngắn, tùy chọn phá hủy, theo yêu cầu rõ ràng của user.

## License: chỉ một file values

Cả hai `30-values-vvp.yaml` có `global.vvp.license.data: {}`. Khối `vvp` ở trong `global`, sau `blobStorage`, trước override subchart. Root chart values không khai báo sẵn khối license; đây là đường dẫn template dùng, không có thứ tự YAML bắt buộc của vendor.

Sau bootstrap, lấy token AppManager, gửi `license_request@ververica.com`, thay `{}` bằng toàn bộ object vendor ngay trong file values hiện có. Không tạo lại heredoc values vì sẽ ghi đè license. Không commit/chia sẻ values đã điền license.

Đã xóa hai example overlay cũ và mọi tham chiếu tới đường dẫn overlay. Helper mặc định đọc `30-values-vvp.yaml`; Helm chỉ dùng một `-f 30-values-vvp.yaml`. Helper LAB kiểm cấu trúc/base64/spec/token/ownership, backup/adopt fingerprint Secret khi cần, không sửa fingerprint data và không xác minh chữ ký mật mã.

Activation nối `&&`: helper → Helm upgrade → delete `vvp-appmanager-0` và `vvp-gateway-0` với namespace, `--ignore-not-found=true --wait=true` → rollout cả hai StatefulSet (300s). Kubernetes luôn truyền post-renderer; OpenShift dùng `KUBECTL=oc` cho helper. Xóa Pod là restart chủ động để nạp license; không suy diễn rằng StatefulSet không recreate Pod.

Trước commit bàn giao, source OpenShift từng có license thật đã được phục hồi từ heredoc placeholder, sau khi xác nhận mọi cấu hình ngoài license khớp nhau. Không lưu bản sao license trong summary.

## Khác biệt profile

| Mục | Kubernetes | OpenShift |
| --- | --- | --- |
| CLI | kubectl | oc |
| Worker | wk-01/wk-02.k8s.bnh.vn | wk-01/wk-02.ocp.bnh.vn |
| StorageClass | vsphere-rwo | thin-csi |
| Platform scheduling | post-renderer nodeSelector LAB | namespace annotation openshift.io/node-selector |
| Runtime defaults | deployment/session nodeSelector LAB trong values | namespace admission selector |
| Exposure | HTTPRoute qua gateway-system/apps-gateway | Route edge TLS |
| Endpoint | http://vvp.apps.k8s.bnh.vn | https://vvp.apps.ocp.bnh.vn |

Post-renderer patch nodeSelector, không patch user/UID. Đã sửa xử lý nodeSelector thiếu/null và giữ selector khác. Đây là thay đổi có sẵn trong working tree từ đầu phiên, đã review và giữ lại.

OpenShift offline render truyền `--api-versions security.openshift.io/v1`. `common.isOpenShift` xét capability HOẶC `global.security.openshift`; không thêm override dư thừa, custom SCC hoặc anyuid. Security helpers bỏ UID/GID/fsGroup cố định nhưng không chứng minh mọi runtime qua SCC.

## OpenShift Route cuối cùng

Host tường minh `vvp.apps.ocp.bnh.vn`, `targetPort: http-alt`, TLS `edge`, insecure policy `Redirect`. Client HTTPS:443 → router kết thúc TLS → Service HTTP:8080. Backend không dùng HTTPS; không đổi sang reencrypt/passthrough. `api-gateway.publicApiEndpoint` và runbook table/values/curl đều là HTTPS mới.

Nếu sau này muốn hostname tự cấp, phải bỏ spec.host và đọc giá trị thật từ Route sau create. Không khẳng định generated hostname chỉ từ convention. DNS phải trỏ router; cert phải bao phủ hostname và client tin CA. Admitted=True chỉ xác nhận router nhận Route, không chứng minh UI/runtime hoạt động.

## PostgreSQL, storage và giới hạn support

- PostgreSQL 15.x external, provider postgresql, createIfMissing=false. SQL có 7 DB; DB operator thứ tám chỉ cần khi bật operator (chart mặc định false).
- Hai profile hiện trỏ cùng host/tên DB và bucket S3 vvp. Không được khẳng định đã tách backend; không chạy hai installation đồng thời trên cùng metadata store.
- PVC vvp, 40Gi; class là override LAB. Service api-gateway có port name http-alt/8080, không lấy port 80 từ ví dụ Ingress.
- Target được ghi nhận OpenShift 4.22.12 / Kubernetes 1.35.6 ngoài dải vendor 1.24–1.34. Việc Pod Running không thay thế xác nhận hỗ trợ vendor. Vanilla Kubernetes chưa được xác minh live.
- Metadata chart version/appVersion 3.1.3 không chứng minh package byte-identical với OCI vendor; kết luận template chỉ áp dụng package local.

## Cleanup: quyết định mới nhất thắng bản phức tạp trước đó

User yêu cầu ngắn gọn, hiện tài liệu giữ: helm uninstall (bỏ qua lỗi) → delete hai namespace --wait → vòng while chờ → delete CRD. Chỉ khác oc/kubectl. Không thêm lại script PV/ownership/local cleanup dài.

Giới hạn được ghi rõ: xóa CRD ảnh hưởng toàn cluster, không chạy nếu có installation khác dùng chung; giữ external PostgreSQL/S3/registry. Không bảo đảm backend volume đã xóa, không gỡ label worker, không xóa .work/backups, không reset license local tự động. Lỗi Helm bị bỏ qua; vòng chờ có thể nhầm lỗi API/quyền với NotFound và không có timeout.

User báo Helm 3.22. Trong chat đã đề xuất bản đơn giản hơn dùng Helm --ignore-not-found, --wait/timeout, nối && và bỏ while; đó là đề xuất, chưa thay block cleanup mà user đã yêu cầu. Nếu muốn đổi, phân biệt rõ quyết định mới với trạng thái file hiện tại.

Cài lại: tự reset license về {}, không chạy lại SQL tạo DB đã tồn tại, xin license theo token mới. Giữ PostgreSQL/S3 đồng nghĩa state cũ (Deployment Target/deployment/artifact) có thể còn; không gọi đây là dữ liệu ứng dụng trắng hoàn toàn.

## Bằng chứng và giới hạn kiểm chứng

Trong phiên đã chạy offline: heredoc cat roundtrip/byte parity; bash -n; render cả hai profile với PyYAML 6.0.3, không có .work; assertions CRD, scheduling/security, Service/PVC và runtime defaults; post-renderer thiếu/null/selector khác; stub smoke token và activation failure ordering, restart Pod; cleanup stub smoke. Không chạy SQL, install/upgrade, helper thật hoặc cleanup lên cluster bằng assistant.

User đã cung cấp output OpenShift: tất cả platform Pod 1/1 Running; appmanager/gateway được tạo lại sau restart; Route HTTP cũ Admitted=True nhưng UI không truy cập được. Đây là bằng chứng do user cung cấp, không phải live verification của assistant. HTTPS hostname mới đã render vào ConfigMap api-gateway-settings; chưa có bằng chứng live DNS/cert/header/UI sau thay đổi. Không kết luận Route là nguyên nhân chắc chắn của lỗi UI, không tuyên bố Flink runtime đã chạy job.

## Git, credentials và bàn giao

User yêu cầu commit/push tới `git@github.com:phamduongw/ververica-platform.git`, cho biết auth đã sẵn sàng và repository private. Sau khi được cảnh báo credential PostgreSQL/S3/registry có trong baseline và commit lịch sử, user xác nhận giữ nguyên tất cả. Vì vậy giữ credential LAB và lịch sử, không sanitize/rewrite ngoài ý muốn. Private repository không thay thế quản trị secret; người được cấp quyền vẫn đọc được credential và history. License thật không được commit.

Hai .gitignore chỉ giữ .work/backups/.venv/__pycache__; không ignore tracked values vì không bảo vệ được file tracked. Không commit log/token/backup/render output. Không force-push hay sửa lịch sử nếu không có yêu cầu mới. Summary không chứa giá trị credential hoặc license.

## Nguồn đã đối chiếu

- https://docs.ververica.com/docs/vvp3/getting-started — rolling 3.1, ví dụ 3.1.1 không thay baseline 3.1.3.
- https://docs.ververica.com/docs/vvp3/user-guides/admin-operator-guide/postgresql-metadata-store
- https://docs.ververica.com/docs/vvp3/user-guides/admin-operator-guide/private-image-registry — không sao chép tag ví dụ 3.1.2.
- https://gateway-api.sigs.k8s.io/guides/user-guides/multiple-ns/
- https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/nodes/controlling-pod-placement-onto-nodes-scheduling#nodes-scheduler-node-selectors-project_nodes-scheduler-node-selectors
- ververica-platform-3.1.3.tgz: prefix ververica-platform/, members Chart.yaml, values.yaml, charts/common/templates/_security.tpl, templates/license-fingerprint-secret.yaml, charts/api-gateway/templates/service.yaml, charts/vvp-appagent/templates/sql-pvc.yaml.

## Khi tiếp tục ở session khác

Đọc summary này rồi hai runbook/source thực tế; working-tree bytes mới nhất là authority, không ghi đè license/customization của user. Chỉ hỏi lại các quyết định có tradeoff thực sự, không khôi phục các phần user đã bỏ. Nếu sửa artifact, đồng bộ heredoc và mọi callsite; source values trong commit phải có license {}. Verify offline trước push và ghi chính xác phần chưa được kiểm live.
