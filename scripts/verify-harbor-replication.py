#!/usr/bin/env python3
import urllib.request
import json
import base64

auth = "Basic " + base64.b64encode(b"admin:ChangeMe123!").decode()
req = urllib.request.Request("http://172.18.0.9:30080/api/v2.0/projects/library/repositories", headers={"Authorization": auth})
with urllib.request.urlopen(req) as resp:
    repos = json.loads(resp.read().decode())
    print(f"Total repositories replicated in Jotunheim Harbor: {len(repos)}")
    for r in repos:
        print(f"  [REPLICATED] {r.get('name')}")
