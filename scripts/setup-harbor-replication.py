#!/usr/bin/env python3
import subprocess
import time
import json
import urllib.request
import urllib.error
import base64

def get_secret(context, ns, secret_name, key):
    cmd = ["kubectl", "--context", context, "-n", ns, "get", "secret", secret_name, "-o", f"jsonpath={{.data.{key}}}"]
    out = subprocess.check_output(cmd).decode().strip()
    return base64.b64decode(out).decode().strip()

def get_node_ip(context):
    cmd = ["kubectl", "--context", context, "get", "nodes", "-l", "node-role.kubernetes.io/control-plane", "-o", "jsonpath={.items[0].status.addresses[?(@.type==\"InternalIP\")].address}"]
    return subprocess.check_output(cmd).decode().strip()

def main():
    print("==> 1. Gathering cluster endpoints and credentials...")
    ygg_admin_pw = get_secret("kind-yggdrasil", "registry-system", "harbor-admin-credentials", "HARBOR_ADMIN_PASSWORD")
    jotun_admin_pw = get_secret("kind-jotunheim", "registry-system", "harbor-admin-credentials", "HARBOR_ADMIN_PASSWORD")

    jotun_node_ip = get_node_ip("kind-jotunheim")
    jotun_registry_url = f"http://{jotun_node_ip}:30080"
    print(f"  Jotunheim Harbor Endpoint URL: {jotun_registry_url}")

    # Port-forward Yggdrasil Harbor
    print("==> 2. Establishing port-forward to Yggdrasil Harbor (svc/harbor:80 -> 18080)...")
    pf = subprocess.Popen([
        "kubectl", "--context", "kind-yggdrasil", "-n", "registry-system",
        "port-forward", "svc/harbor", "18080:80"
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(3)

    try:
        ygg_base = "http://127.0.0.1:18080/api/v2.0"
        auth_header = "Basic " + base64.b64encode(f"admin:{ygg_admin_pw}".encode()).decode()

        # 3. Test ping to Jotunheim Harbor endpoint from Yggdrasil Harbor
        print(f"==> 3. Testing Harbor-to-Harbor ping from Yggdrasil to Jotunheim ({jotun_registry_url})...")
        ping_payload = {
            "name": "jotunheim-registry",
            "type": "harbor",
            "url": jotun_registry_url,
            "credential": {
                "type": "basic",
                "access_key": "admin",
                "access_secret": jotun_admin_pw
            },
            "insecure": True
        }
        
        req = urllib.request.Request(
            f"{ygg_base}/registries/ping",
            data=json.dumps(ping_payload).encode(),
            headers={"Content-Type": "application/json", "Authorization": auth_header},
            method="POST"
        )
        try:
            with urllib.request.urlopen(req) as resp:
                print(f"  [SUCCESS] Ping response: {resp.status}")
        except urllib.error.HTTPError as e:
            err = e.read().decode()
            print(f"  [PING RESULT] HTTP {e.code}: {err}")

        # 4. Check or Create Registry Endpoint
        print("==> 4. Checking if 'jotunheim-registry' endpoint exists in Yggdrasil Harbor...")
        req = urllib.request.Request(
            f"{ygg_base}/registries",
            headers={"Authorization": auth_header}
        )
        with urllib.request.urlopen(req) as resp:
            registries = json.loads(resp.read().decode())
        
        reg_id = None
        for reg in registries:
            if reg.get("name") == "jotunheim-registry":
                reg_id = reg.get("id")
                print(f"  [EXISTS] Found existing registry endpoint ID: {reg_id}")
                break
        
        if reg_id is None:
            print("  Creating new registry endpoint 'jotunheim-registry'...")
            reg_payload = {
                "name": "jotunheim-registry",
                "description": "Secondary Jotunheim Harbor Registry across Kilo WireGuard Mesh",
                "type": "harbor",
                "url": jotun_registry_url,
                "credential": {
                    "type": "basic",
                    "access_key": "admin",
                    "access_secret": jotun_admin_pw
                },
                "insecure": True
            }
            req = urllib.request.Request(
                f"{ygg_base}/registries",
                data=json.dumps(reg_payload).encode(),
                headers={"Content-Type": "application/json", "Authorization": auth_header},
                method="POST"
            )
            with urllib.request.urlopen(req) as resp:
                loc = resp.headers.get("Location")
                reg_id = int(loc.split("/")[-1])
                print(f"  [SUCCESS] Registry endpoint created with ID: {reg_id}")

        # 5. Check or Create Replication Policy
        print("==> 5. Checking if replication policy exists...")
        req = urllib.request.Request(
            f"{ygg_base}/replication/policies",
            headers={"Authorization": auth_header}
        )
        with urllib.request.urlopen(req) as resp:
            policies = json.loads(resp.read().decode())

        policy_id = None
        for pol in policies:
            if pol.get("name") == "replicate-to-jotunheim":
                policy_id = pol.get("id")
                print(f"  [EXISTS] Found existing policy ID: {policy_id}")
                break

        if policy_id is None:
            print("  Creating replication policy 'replicate-to-jotunheim' (Push-based, Event-based & Manual)...")
            policy_payload = {
                "name": "replicate-to-jotunheim",
                "description": "Replicate library project artifacts to Jotunheim Harbor",
                "src_registry": None, # Local registry
                "dest_registry": {"id": reg_id},
                "dest_namespace": "library",
                "trigger": {
                    "type": "event_based",
                    "trigger_settings": {}
                },
                "filters": [
                    {
                        "type": "name",
                        "value": "library/**"
                    }
                ],
                "deletion": True,
                "override": True,
                "enabled": True
            }
            req = urllib.request.Request(
                f"{ygg_base}/replication/policies",
                data=json.dumps(policy_payload).encode(),
                headers={"Content-Type": "application/json", "Authorization": auth_header},
                method="POST"
            )
            with urllib.request.urlopen(req) as resp:
                loc = resp.headers.get("Location")
                policy_id = int(loc.split("/")[-1])
                print(f"  [SUCCESS] Replication policy created with ID: {policy_id}")

        # 6. Ensure project 'library' exists in Jotunheim Harbor
        print("==> 6. Ensuring project 'library' exists in Jotunheim Harbor...")
        # Port-forward to Jotunheim Harbor
        pf_jotun = subprocess.Popen([
            "kubectl", "--context", "kind-jotunheim", "-n", "registry-system",
            "port-forward", "svc/harbor", "18081:80"
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(3)
        try:
            jotun_base = "http://127.0.0.1:18081/api/v2.0"
            jotun_auth = "Basic " + base64.b64encode(f"admin:{jotun_admin_pw}".encode()).decode()
            req = urllib.request.Request(
                f"{jotun_base}/projects",
                headers={"Authorization": jotun_auth}
            )
            with urllib.request.urlopen(req) as resp:
                projects = json.loads(resp.read().decode())
            
            has_lib = any(p.get("name") == "library" for p in projects)
            if not has_lib:
                print("  Creating 'library' project in Jotunheim Harbor...")
                req = urllib.request.Request(
                    f"{jotun_base}/projects",
                    data=json.dumps({"project_name": "library", "metadata": {"public": "true"}}).encode(),
                    headers={"Content-Type": "application/json", "Authorization": jotun_auth},
                    method="POST"
                )
                with urllib.request.urlopen(req) as resp:
                    print("  [SUCCESS] Created 'library' project on Jotunheim.")
            else:
                print("  [EXISTS] 'library' project exists in Jotunheim.")
        finally:
            pf_jotun.terminate()

        # 7. Trigger a manual execution of the replication policy to sync existing images
        print(f"==> 7. Triggering replication execution for policy ID {policy_id}...")
        req = urllib.request.Request(
            f"{ygg_base}/replication/executions",
            data=json.dumps({"policy_id": policy_id}).encode(),
            headers={"Content-Type": "application/json", "Authorization": auth_header},
            method="POST"
        )
        with urllib.request.urlopen(req) as resp:
            loc = resp.headers.get("Location")
            exec_id = int(loc.split("/")[-1])
            print(f"  [SUCCESS] Triggered execution ID: {exec_id}")

        print("==> 8. Monitoring replication execution progress...")
        for _ in range(15):
            time.sleep(3)
            req = urllib.request.Request(
                f"{ygg_base}/replication/executions/{exec_id}",
                headers={"Authorization": auth_header}
            )
            with urllib.request.urlopen(req) as resp:
                exec_data = json.loads(resp.read().decode())
                status = exec_data.get("status")
                succeed = exec_data.get("succeed", 0)
                failed = exec_data.get("failed", 0)
                total = exec_data.get("total", 0)
                print(f"  Execution status: {status} (Succeeded: {succeed}, Failed: {failed}, Total: {total})")
                if status in ("Success", "Failed", "Stopped"):
                    break

        print("\n==> HARBOR REPLICATION CONFIGURATION COMPLETE <==")

    finally:
        pf.terminate()

if __name__ == "__main__":
    main()
