#!/usr/bin/env python3
"""
scraper.py — Generic web scraper with requests + BeautifulSoup (regex fallback).

Extracts titles, links, and visible text from a given URL.
Supports --output to save results as JSON.

Usage:
    python scraper.py https://example.com
    python scraper.py https://example.com --output data.json
    python scraper.py https://example.com --user-agent "Mozilla/5.0" --timeout 15
"""

import argparse
import json
import logging
import re
import sys
from typing import Optional

logger = logging.getLogger("scraper")


# ---------------------------------------------------------------------------
# extraction backends
# ---------------------------------------------------------------------------

def extract_with_beautifulsoup(html: str, base_url: str) -> dict:
    """Extract title, links, and visible text using BeautifulSoup."""
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(html, "html.parser")

    # title
    title = ""
    if soup.title and soup.title.string:
        title = soup.title.string.strip()
    elif soup.h1:
        title = soup.h1.get_text(strip=True)

    # links
    links = []
    seen = set()
    for a_tag in soup.find_all("a", href=True):
        href = a_tag["href"].strip()
        if href.startswith("javascript:") or href.startswith("#"):
            continue
        # build absolute URL
        from urllib.parse import urljoin
        abs_url = urljoin(base_url, href)
        if abs_url not in seen:
            seen.add(abs_url)
            text = a_tag.get_text(strip=True) or ""
            links.append({"url": abs_url, "text": text[:200]})

    # visible text
    for tag in soup(["script", "style", "noscript", "meta", "link"]):
        tag.decompose()
    text = soup.get_text(separator="\n", strip=True)
    # collapse excessive whitespace
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    text = "\n".join(lines)

    return {"title": title, "links": links, "text": text}


def extract_with_regex(html: str, base_url: str) -> dict:
    """Extract title, links, and visible text using regex (fallback)."""
    title = ""
    m = re.search(
        r'<title[^>]*>\s*(.*?)\s*</title>', html, re.IGNORECASE | re.DOTALL
    )
    if m:
        title = m.group(1).strip()
    else:
        m = re.search(
            r'<h1[^>]*>\s*(.*?)\s*</h1>', html, re.IGNORECASE | re.DOTALL
        )
        if m:
            title = re.sub(r'<[^>]+>', '', m.group(1)).strip()

    # links
    links = []
    seen = set()
    from urllib.parse import urljoin
    for m in re.finditer(
        r'<a[^>]+href\s*=\s*["\']\s*([^"\'\s]+)\s*["\'][^>]*>',
        html,
        re.IGNORECASE,
    ):
        href = m.group(1).strip()
        if href.startswith("javascript:") or href.startswith("#"):
            continue
        abs_url = urljoin(base_url, href)
        if abs_url not in seen:
            seen.add(abs_url)
            # try to grab link text after the anchor tag
            text_m = re.search(
                re.escape(m.group(0)) + r"\s*(.*?)\s*</a>",
                html,
                re.DOTALL | re.IGNORECASE,
            )
            text = ""
            if text_m:
                text = re.sub(r'<[^>]+>', '', text_m.group(1)).strip()[:200]
            links.append({"url": abs_url, "text": text})

    # visible text: strip tags, collapse whitespace
    text = re.sub(r'<[^>]+>', ' ', html)
    text = re.sub(r'\s+', ' ', text).strip()

    return {"title": title, "links": links, "text": text}


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generic web scraper — extract titles, links, and text."
    )
    parser.add_argument("url", help="Target URL to scrape")
    parser.add_argument(
        "--output", "-o",
        help="Save output as JSON to this file (prints to stdout if omitted)",
    )
    parser.add_argument(
        "--user-agent",
        default=(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/125.0.0.0 Safari/537.36"
        ),
        help="Custom User-Agent header",
    )
    parser.add_argument(
        "--timeout", type=int, default=10, help="Request timeout in seconds"
    )
    parser.add_argument(
        "--force-regex",
        action="store_true",
        help="Skip BeautifulSoup and use regex fallback only",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Enable debug logging"
    )
    return parser.parse_args(argv)


def main() -> None:
    args = parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s | %(message)s",
    )

    # try BS4 first unless --force-regex
    use_bs4 = False
    if not args.force_regex:
        try:
            import bs4  # noqa: F401 — test presence
            use_bs4 = True
        except ImportError:
            logger.info("BeautifulSoup not installed; falling back to regex")

    # fetch
    import requests

    logger.info("Fetching %s …", args.url)
    try:
        resp = requests.get(
            args.url,
            headers={"User-Agent": args.user_agent},
            timeout=args.timeout,
        )
        resp.raise_for_status()
    except requests.exceptions.RequestException as exc:
        logger.error("Request failed: %s", exc)
        sys.exit(1)

    html = resp.text
    base_url = resp.url  # follow redirects

    # extract
    if use_bs4:
        data = extract_with_beautifulsoup(html, base_url)
    else:
        data = extract_with_regex(html, base_url)

    data["url"] = base_url
    data["status"] = resp.status_code

    # output
    output = json.dumps(data, indent=2, ensure_ascii=False)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(output)
        logger.info("Saved %d bytes to %s", len(output), args.output)
    else:
        print(output)


if __name__ == "__main__":
    main()
