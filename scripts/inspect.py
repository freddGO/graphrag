"""Print the GraphRAG index: entities, relationships, communities and reports.

    ./scripts/inspect.sh                  # everything, descriptions truncated
    ./scripts/inspect.sh --full           # no truncation
    ./scripts/inspect.sh reports          # one section: entities|relationships|communities|reports

Reads the tables from the deployed API (GET /tables/{name}), which loads them
from the output/ folder in blob storage. Standard library only, so it runs on
any machine with Python, no pandas/pyarrow needed.
"""
import json
import os
import sys
import textwrap
import urllib.request

sys.stdout.reconfigure(encoding="utf-8")  # descriptions contain non-ASCII punctuation

API_URL = os.environ["API_URL"].rstrip("/")
API_KEY = os.environ["API_KEY"]
FULL = "--full" in sys.argv
SECTIONS = [a for a in sys.argv[1:] if not a.startswith("--")] or ["entities", "relationships", "communities", "reports"]
WIDTH = 100


def fetch(table):
    req = urllib.request.Request(f"{API_URL}/tables/{table}", headers={"X-API-Key": API_KEY})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read())


def short(text, limit=160):
    text = " ".join(str(text or "").split())
    return text if FULL or len(text) <= limit else text[: limit - 1] + "…"


def wrap(text, indent="      "):
    return textwrap.fill(short(text), WIDTH, initial_indent=indent, subsequent_indent=indent)


def heading(title):
    print(f"\n{'=' * WIDTH}\n{title}\n{'=' * WIDTH}")


entities = fetch("entities")
by_id = {e["id"]: e["title"] for e in entities}

if "entities" in SECTIONS:
    heading(f"ENTITIES ({len(entities)})  sorted by degree = number of relationships")
    for e in sorted(entities, key=lambda e: -e.get("degree", 0)):
        chunks = len(set(e.get("text_unit_ids") or []))
        print(f"\n  [{e['human_readable_id']:>2}] {e['title']}  ({e['type']})  "
              f"degree={e.get('degree')}  chunks={chunks}")
        print(wrap(e.get("description")))

if "relationships" in SECTIONS:
    rels = fetch("relationships")
    heading(f"RELATIONSHIPS ({len(rels)})  sorted by weight")
    for r in sorted(rels, key=lambda r: -r.get("weight", 0)):
        print(f"\n  [{r['human_readable_id']:>2}] {r['source']} -- {r['target']}  "
              f"weight={r.get('weight')}  combined_degree={r.get('combined_degree')}")
        print(wrap(r.get("description")))

if "communities" in SECTIONS:
    comms = fetch("communities")
    heading(f"COMMUNITIES ({len(comms)})  from hierarchical Leiden")
    for c in sorted(comms, key=lambda c: (c["level"], c["community"])):
        members = sorted(by_id.get(i, i) for i in c.get("entity_ids") or [])
        print(f"\n  community {c['community']}  level={c['level']}  parent={c['parent']}  size={c.get('size')}")
        print(wrap(", ".join(members)))

if "reports" in SECTIONS:
    reports = fetch("community_reports")
    heading(f"COMMUNITY REPORTS ({len(reports)})")
    for r in sorted(reports, key=lambda r: -float(r.get("rank") or 0)):
        print(f"\n  community {r['community']}: {r['title']}   rank={r.get("rank")}/10")
        print(wrap(r.get("summary")))
        if r.get("rating_explanation"):
            print(wrap(f"Why this rating: {r['rating_explanation']}"))
        for f in r.get("findings") or []:
            summary = f.get("summary") if isinstance(f, dict) else f
            print(textwrap.fill(f"- {short(summary, 140)}", WIDTH, initial_indent="      ", subsequent_indent="        "))
