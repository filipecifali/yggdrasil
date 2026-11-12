#!/usr/bin/env python3
"""
audit-security-contexts.py
Audits all pods in the cluster against Pod Security Standards (Restricted/Baseline).
Identifies missing securityContext, un-dropped capabilities, and privilege escalation.
"""

import json
import subprocess
import sys

def main():
    cmd = ["kubectl", "get", "pods", "-A", "-o", "json"]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
    data = json.loads(proc.stdout)

    print(f"{'NAMESPACE':<22} {'POD':<42} {'CONTAINER':<20} {'NON-ROOT':<10} {'NO-ESC':<8} {'DROP-ALL':<10} {'RO-FS':<8}")
    print("=" * 125)

    violations = 0
    for pod in data["items"]:
        ns = pod["metadata"]["namespace"]
        name = pod["metadata"]["name"]
        spec = pod["spec"]
        pod_sc = spec.get("securityContext", {})

        # Skip system daemonsets/infrastructure like calico, kube-system, cilium if expected
        for c in spec.get("containers", []):
            cname = c["name"]
            csc = c.get("securityContext", {})
            caps = csc.get("capabilities", {})
            dropped = caps.get("drop", [])
            escalation = csc.get("allowPrivilegeEscalation")
            ro = csc.get("readOnlyRootFilesystem", False)
            non_root = csc.get("runAsNonRoot") if "runAsNonRoot" in csc else pod_sc.get("runAsNonRoot", False)
            drop_all = "ALL" in dropped

            is_hardened = non_root and (escalation is False) and drop_all
            if not is_hardened:
                violations += 1
                print(f"{ns:<22} {name[:40]:<42} {cname[:18]:<20} {str(non_root):<10} {str(escalation is False):<8} {str(drop_all):<10} {str(ro):<8}")

    print("=" * 125)
    print(f"Total workload containers requiring security evaluation: {violations}")

if __name__ == "__main__":
    main()
