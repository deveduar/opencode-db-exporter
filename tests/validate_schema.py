#!/usr/bin/env python3
"""Tiny JSON-Schema (draft-07 subset) validator for the repo contract schemas.

Supports exactly what the schemas use: `$ref`, `type` (object/string/integer/
boolean), `properties`, `patternProperties`, `additionalProperties`, `required`,
`enum`, `minimum`, `minItems`, `minLength`, `minProperties`, `oneOf`, `not`.
`title`/`description`/`$id`/`$schema` are ignored.

Usage: validate_schema.py <schema.json> <instance.json>  (exit 0/1)

Test-only tool: keeps the smoke suite dependency-free (stdlib only) while still
verifying that presets.json.example satisfies presets.schema.json.
"""
import json
import re
import sys


def resolve(root, ref):
    if ref.startswith("#/definitions/"):
        cur = root
        for part in ("definitions" + ref[len("#/definitions"):]).split("/"):
            cur = cur[part]
        return cur
    return root


def errs(root, schema, data, path):
    out = []
    if "$ref" in schema:
        out += errs(root, resolve(root, schema["$ref"]), data, path)
    if "not" in schema:
        if not errs(root, schema["not"], data, path):
            out.append(f"{path}: must NOT satisfy the 'not' schema")
    if "oneOf" in schema:
        formats = [list(errs(root, s, data, path)) for s in schema["oneOf"]]
        if sum(1 for f in formats if not f) != 1:
            out.append(f"{path}: must match exactly one of oneOf ({sum(1 for f in formats if not f)} matched)")
    if "type" in schema:
        t = schema["type"]
        ok = {"object": isinstance(data, dict), "string": isinstance(data, str),
              "integer": isinstance(data, int) and not isinstance(data, bool),
              "boolean": isinstance(data, bool)}.get(t, False)
        if not ok:
            out.append(f"{path}: expected {t}, got {type(data).__name__}")
            return out  # type is final for the other keywords below
    if isinstance(data, dict):
        props = schema.get("properties", {})
        pats = [(re.compile(p), v) for p, v in schema.get("patternProperties", {}).items()]
        ap = schema.get("additionalProperties")
        for k, v in data.items():
            covered = k in props or any(p.match(k) for p, _ in pats)
            if not covered:
                if ap is False:
                    out.append(f"{path}.{k}: additionalProperties is false")
                elif isinstance(ap, dict):
                    out += errs(root, ap, v, f"{path}.{k}")
        required = schema.get("required", [])
        for k in required:
            if k not in data:
                out.append(f"{path}: missing required key '{k}'")
        for k, sub in props.items():
            if k in data:
                out += errs(root, sub, data[k], f"{path}.{k}")
        for p, sub in pats:
            for k, v in data.items():
                if p.match(k):
                    out += errs(root, sub, v, f"{path}.{k}")
        if "minProperties" in schema and len(data) < schema["minProperties"]:
            out.append(f"{path}: too few properties (< {schema['minProperties']})")
    if isinstance(data, (list, str)) and "minItems" in schema and len(data) < schema["minItems"]:
        out.append(f"{path}: too few items (< {schema['minItems']})")
    if isinstance(data, str) and "minLength" in schema and len(data) < schema["minLength"]:
        out.append(f"{path}: string too short (< {schema['minLength']})")
    if schema.get("enum") is not None:
        if data not in schema["enum"]:
            out.append(f"{path}: {data!r} not in enum {schema['enum']}")
    if isinstance(data, int) and not isinstance(data, bool) and "minimum" in schema and data < schema["minimum"]:
        out.append(f"{path}: {data} < minimum {schema['minimum']}")
    return out


def main():
    if len(sys.argv) != 3:
        print("usage: validate_schema.py <schema.json> <instance.json>", file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as f:
        schema = json.load(f)
    with open(sys.argv[2], encoding="utf-8") as f:
        instance = json.load(f)
    problems = errs(schema, schema, instance, "$")
    if problems:
        for p in problems:
            print(f"schema error: {p}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())