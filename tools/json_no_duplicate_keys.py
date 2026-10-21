"""Fails when a JSON file has an object with the same key twice.

    python3 tools/json_no_duplicate_keys.py FILE...

openapi-spec-validator reads the document with Python's json, which keeps the
last of two equal keys without a word; Swagger UI parses it as YAML and refuses
the whole document ("duplicated mapping key"). Until 0.23.1 a property with a
Format on a type that already had one (a date-time) wrote "format" twice, and
only a browser showed it (pascal-agenda-faa's /swagger). Run before the
validator.
"""
import json
import sys


def main(paths):
    failed = False
    for path in paths:
        found = []

        def hook(pairs, found=found):
            seen = set()
            for key, _ in pairs:
                if key in seen:
                    found.append((key, [k for k, _ in pairs]))
                seen.add(key)
            return dict(pairs)

        with open(path, encoding="utf-8") as f:
            json.load(f, object_pairs_hook=hook)
        for key, keys in found:
            print("%s: duplicated key %r in an object with keys %s" % (path, key, keys))
        if found:
            failed = True
        else:
            print("%s: no duplicated keys" % path)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
