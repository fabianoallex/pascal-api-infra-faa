"""Drives a sample's /mcp endpoint with the official MCP Python SDK (mcp 2.0.0,
protocol 2026-07-28): connects in "auto" mode (server/discover first), lists
the tools and calls some, as an AI client would.

    python3 tools/mcp_client_check.py 01 http://127.0.0.1:9310   (logs in for a token)
    python3 tools/mcp_client_check.py 02 http://127.0.0.1:9330

Exit code 0 only if every check passed. Run by tools/test_http_docker.sh
(CI); needs `pip install mcp==2.0.0`.
"""
import asyncio
import json
import sys
import urllib.request

import httpx2
from mcp.client import Client
from mcp.client.streamable_http import streamable_http_client

FAILS = []


def check(cond, label):
    print(("ok   " if cond else "FAIL ") + label)
    if not cond:
        FAILS.append(label)


def login(base):
    req = urllib.request.Request(base + "/auth/login", data=b'{"user":"sdk"}', method="POST")
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["token"]


async def run(sample, base):
    headers = {}
    if sample == "01":
        headers["Authorization"] = "Bearer " + login(base)
    async with httpx2.AsyncClient(headers=headers) as http:
        async with Client(streamable_http_client(base + "/mcp", http_client=http)) as client:
            check(client.protocol_version == "2026-07-28", "negotiated 2026-07-28 (%s)" % client.protocol_version)
            check(client.server_info is not None and client.server_info.name != "", "server info")
            tools = {t.name: t for t in (await client.list_tools()).tools}
            check("get_citie" in tools and "list_citie" in tools, "tools listed: %s" % sorted(tools))
            check(tools["get_citie"].input_schema.get("additionalProperties") is False, "input schema")

            if sample == "01":
                r = await client.call_tool("list_me", {})
                check(not r.is_error and '"sub":"sdk"' in r.content[0].text, "token passed on: %s" % r.content[0].text)
                r = await client.call_tool("list_citie", {"limit": 2, "orderBy": "name"})
                page = json.loads(r.content[0].text)
                check(not r.is_error and page["limit"] == 2 and len(page["items"]) == 2, "GET with query arguments")
                r = await client.call_tool("get_citie", {"id": 999})
                check(r.is_error and "not found" in r.content[0].text, "route error as isError")
            else:
                r = await client.call_tool("list_citie", {"state": "SC", "limit": 50})
                page = json.loads(r.content[0].text)
                check(not r.is_error and all(c["state"] == "SC" for c in page["items"]) and page["total"] >= 1,
                      "filter reaches the route")
                r = await client.call_tool("get_citie", {"code": "0000000"})
                check(r.is_error, "route error as isError")
                r = await client.call_tool("create_citie", {"code": "123", "name": "X", "state": "SC"})
                check(r.is_error, "invalid body as isError")


def main():
    sample, base = sys.argv[1], sys.argv[2].rstrip("/")
    asyncio.run(run(sample, base))
    print("%s: %d failed" % (sys.argv[0], len(FAILS)))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
