import subprocess
import json

out = subprocess.check_output(["docker", "network", "inspect", "kind"])
data = json.loads(out)[0]["Containers"]
for cid, info in sorted(data.items(), key=lambda x: x[1]["Name"]):
    print(f"{info['Name']:35} {info['IPv4Address']}")
