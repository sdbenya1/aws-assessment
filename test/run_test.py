#!/usr/bin/env python3
import argparse
import json
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
import requests


def now_ms() -> float:
    return time.perf_counter() * 1000.0


def cognito_login(region: str, client_id: str, username: str, password: str) -> str:
    """Return a JWT (IdToken) using USER_PASSWORD_AUTH."""
    idp = boto3.client("cognito-idp", region_name=region)
    resp = idp.initiate_auth(
        AuthFlow="USER_PASSWORD_AUTH",
        ClientId=client_id,
        AuthParameters={"USERNAME": username, "PASSWORD": password},
    )
    return resp["AuthenticationResult"]["IdToken"]


def call_api(url: str, jwt: str) -> dict:
    """POST to an endpoint with Bearer JWT; return response JSON + latency."""
    headers = {"Authorization": f"Bearer {jwt}"}
    start = now_ms()
    r = requests.post(url, headers=headers, json={}, timeout=30)
    latency = now_ms() - start

    # API Gateway HTTP API returns JSON; /greet returns {"region": "..."}
    try:
        body = r.json()
    except Exception:
        body = {"raw": r.text}

    return {"url": url, "status": r.status_code, "latency_ms": round(latency, 2), "body": body}


def main():
    p = argparse.ArgumentParser(description="Unleash live AWS assessment test runner")
    p.add_argument("--cognito-region", default="us-east-1")
    p.add_argument("--client-id", required=True)
    p.add_argument("--username", required=True)
    p.add_argument("--password", required=True)

    p.add_argument("--us-base", required=True, help="e.g. https://xxxx.execute-api.us-east-1.amazonaws.com")
    p.add_argument("--eu-base", required=True, help="e.g. https://yyyy.execute-api.eu-west-1.amazonaws.com")

    args = p.parse_args()

    print("Authenticating with Cognito...")
    jwt = cognito_login(args.cognito_region, args.client_id, args.username, args.password)
    print("JWT acquired.\n")

    greet_targets = [
        ("us-east-1", f"{args.us_base}/greet"),
        ("eu-west-1", f"{args.eu_base}/greet"),
    ]
    dispatch_targets = [
        ("us-east-1", f"{args.us_base}/dispatch"),
        ("eu-west-1", f"{args.eu_base}/dispatch"),
    ]

    def run_group(name: str, targets):
        print(f"=== {name} (concurrent) ===")
        results = []
        with ThreadPoolExecutor(max_workers=4) as ex:
            fut_map = {ex.submit(call_api, url, jwt): (region, url) for region, url in targets}
            for fut in as_completed(fut_map):
                region, url = fut_map[fut]
                res = fut.result()
                res["expected_region"] = region
                results.append(res)

        # Print + assertions
        for r in sorted(results, key=lambda x: x["expected_region"]):
            status = r["status"]
            latency = r["latency_ms"]
            body = r["body"]

            ok = True
            if name == "GREET":
                got_region = body.get("region")
                ok = (status == 200) and (got_region == r["expected_region"])
                print(f"[{r['expected_region']}] {status} {latency}ms  body.region={got_region}  ok={ok}")
                if not ok:
                    raise SystemExit(f"GREET assertion failed for {r['expected_region']}: {json.dumps(r, indent=2)}")
            else:
                # DISPATCH returns {ok:true, tasks:[...]} if lambda succeeded
                ok_flag = body.get("ok")
                ok = (status == 200) and (ok_flag is True)
                print(f"[{r['expected_region']}] {status} {latency}ms  ok={ok_flag}  ok={ok}")
                if not ok:
                    raise SystemExit(f"DISPATCH assertion failed for {r['expected_region']}: {json.dumps(r, indent=2)}")

        # Show quick latency comparison
        lat_by_region = {r["expected_region"]: r["latency_ms"] for r in results}
        if "us-east-1" in lat_by_region and "eu-west-1" in lat_by_region:
            diff = round(lat_by_region["eu-west-1"] - lat_by_region["us-east-1"], 2)
            print(f"Latency difference (eu - us): {diff}ms\n")
        else:
            print()

    run_group("GREET", greet_targets)
    run_group("DISPATCH", dispatch_targets)

    print("All checks passed.")


if __name__ == "__main__":
    main()