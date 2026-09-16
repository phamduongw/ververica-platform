#!/usr/bin/env python3
import sys
import yaml

NODE_SELECTOR = {
    "workload.ververica.io/pool": "lab"
}

def patch_pod_spec(pod_spec):
    selector = pod_spec.get("nodeSelector")
    if selector is None:
        selector = {}
        pod_spec["nodeSelector"] = selector
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
