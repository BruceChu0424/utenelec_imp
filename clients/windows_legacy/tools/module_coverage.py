#!/usr/bin/env python3
"""Inventory Flutter routes/pages without treating a native shell as migrated ERP.

This reads repository source only. It never contacts the business service or changes
Flutter/backend sources. Re-run after route changes; --check detects a stale manifest.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "clients/windows_legacy/migration-coverage.json"
ROUTE_NAMES = "lib/core/router/route_names.dart"
ROUTER = "lib/core/router/app_router.dart"
GOODS_NATIVE = "clients/windows_legacy/Uten.Legacy.Desktop/Features/Goods/GoodsWorkspaceView.cs"
PARTIAL_ROUTES = {
    "/basicinfo/goods": "native category/list/search/pagination reads; no create/edit/delete/import/export/BOM workflows",
    "/basicinfo/goods/:id": "native selected-row detail read; dedicated route/deep links and editing are not migrated",
}
PARTIAL_PAGES = {
    "lib/features/basic_data/pages/product_category_page.dart",
    "lib/features/basic_data/pages/goods_detail_page.dart",
}


def _resolve(expression: str, constants: dict[str, str]) -> str | None:
    expression = expression.strip()
    if re.fullmatch(r"RouteName\.\w+", expression):
        return constants.get(expression.split(".", 1)[1])
    strings = re.findall(r"'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"", expression)
    if not strings:
        return None
    value = "".join(item[1:-1] for item in strings)
    value = re.sub(r"\$\{(?:RouteName\.)?(\w+)\}|\$(\w+)",
                   lambda match: constants.get(match.group(1) or match.group(2), match.group(0)), value)
    return value if "$" not in value and value.startswith("/") else None


def collect() -> dict:
    names_text = (ROOT / ROUTE_NAMES).read_text(encoding="utf-8")
    router_text = (ROOT / ROUTER).read_text(encoding="utf-8")
    declarations = list(re.finditer(r"static\s+const\s+String\s+(\w+)\s*=\s*(.*?);", names_text, re.S))
    constants = {}
    for _ in range(len(declarations) + 1):
        changed = False
        for match in declarations:
            value = _resolve(match.group(2), constants)
            if value is not None and constants.get(match.group(1)) != value:
                constants[match.group(1)] = value
                changed = True
        if not changed:
            break
    routes = []
    pattern = r"\bpath\s*:\s*(RouteName\.\w+|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"|[^\r\n,]+)"
    for match in re.finditer(pattern, router_text):
        expression = match.group(1).strip()
        path = _resolve(expression, constants)
        partial = path in PARTIAL_ROUTES
        entry = {"source": ROUTER, "line": router_text.count("\n", 0, match.start()) + 1,
                 "expression": expression, "path": path,
                 "status": "partial-native-readonly" if partial else "not-migrated"}
        if partial:
            entry.update({"nativeSource": GOODS_NATIVE, "boundary": PARTIAL_ROUTES[path],
                          "validation": "source-implementation; target-machine acceptance pending"})
        routes.append(entry)
    pages = []
    for source in sorted((ROOT / "lib/features").rglob("*_page.dart")):
        relative = source.relative_to(ROOT).as_posix()
        pages.append({"source": relative,
                      "status": "partial-native-readonly" if relative in PARTIAL_PAGES else "not-migrated"})
    declared = [{"constant": match.group(1), "path": constants.get(match.group(1)),
                 "line": names_text.count("\n", 0, match.start()) + 1,
                 "referencedByRouter": bool(re.search(r"\bRouteName\." + re.escape(match.group(1)) + r"\b", router_text))}
                for match in declarations]
    return {
        "schemaVersion": 1,
        "status": "incomplete-native-migration",
        "releaseReady": False,
        "fullErpEquivalent": False,
        "scope": "Native C# WPF .NET Framework 4.8 client; no embedded browser",
        "sourceFingerprints": {ROUTE_NAMES: hashlib.sha256(names_text.encode("utf-8")).hexdigest(),
                               ROUTER: hashlib.sha256(router_text.encode("utf-8")).hexdigest()},
        "summary": {"declaredRouteConstants": len(declared), "routerPathExpressions": len(routes),
                    "pageEntrypoints": len(pages), "fullyMigratedBusinessWorkflows": 0,
                    "partialReadOnlyRoutes": sum(item["status"] == "partial-native-readonly" for item in routes),
                    "unmigratedRouteExpressions": sum(item["status"] == "not-migrated" for item in routes)},
        "implementedReadContract": {
            "categories": {"method": "GET", "path": "/master/material-categories/tree", "permission": "material_category:view"},
            "goodsPage": {"method": "GET", "path": "/master/goods", "permission": "goods:view", "pageBase": 1,
                          "filters": ["categoryId", "keyword", "page", "size"]},
            "goodsDetail": {"method": "GET", "path": "/master/goods/{UUID}", "permission": "goods:view"},
            "authority": "Existing server authorization, read scope and business calculations remain authoritative",
            "precision": "Numeric JSON lexemes are retained as text; client performs no financial/quantity computation",
        },
        "notMigrated": ["transaction writes and their approvals/idempotency/unknown-submit recovery",
                        "BOM, costs, inventory movement, procurement, subcontract, production and finance workflows",
                        "attachments/import/export/printing, MFA step-up, release/update and complete route navigation",
                        "cross-module regression and Win7 x86/x64 visual/performance/user acceptance"],
        "declaredRoutes": declared,
        "routerPaths": routes,
        "pageEntrypoints": pages,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail when the saved manifest differs from current source")
    args = parser.parse_args()
    manifest = collect()
    rendered = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_text(encoding="utf-8") != rendered:
            raise SystemExit("Migration coverage is stale; run module_coverage.py to regenerate it.")
    else:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(rendered, encoding="utf-8")
    print(json.dumps(manifest["summary"], ensure_ascii=False))


if __name__ == "__main__":
    main()
