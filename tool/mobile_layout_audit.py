"""Inventory every Flutter page source and its shared responsive consumers.

This is a source inventory, not a declaration of interactive/target-device UAT.
Run from the repository root; output is deterministic and contains no data.
"""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "docs/99-项目治理/全平台整改交接/mobile-layout-20261102-inventory.json"
SHARED = {
    "compactPolicy": "lib/core/responsive/compact_presentation.dart",
    "density": "lib/core/theme/uten_control_theme.dart",
    "button": "lib/components/buttons/uten_button.dart",
    "actionMenu": "lib/components/layout/uten_action_overflow.dart",
    "anchoredPopup": "lib/components/layout/uten_anchored_popup.dart",
    "search": "lib/components/inputs/uten_search_bar.dart",
    "compactToolbar": "lib/components/layout/uten_compact_toolbar.dart",
    "rootModal": "lib/components/feedback/uten_modal_bottom_sheet.dart",
    "caretClearance": "lib/components/inputs/uten_caret_scroll_clearance.dart",
    "table": "lib/features/basic_data/widgets/master_data_table_view.dart",
    "editableGrid": "lib/components/layout/uten_editable_grid.dart",
    "linkedScroll": "lib/components/layout/uten_collapsing_header_scroll_view.dart",
    "floatingActions": "lib/components/layout/uten_floating_action_group.dart",
    "pagedGrid": "lib/components/layout/uten_paged_grid.dart",
    "card": "lib/components/cards/uten_card.dart",
}


def imported_files(path: Path, source: str) -> list[Path]:
    result = []
    for target in re.findall(r"(?:import|export|part)\s+['\"]([^'\"]+)['\"]", source):
        if target.startswith("package:uten_imp/"):
            other = ROOT / "lib" / target.removeprefix("package:uten_imp/")
        elif ":" in target:
            continue
        else:
            other = path.parent / target
        other = other.resolve()
        if other.is_file() and other.is_relative_to(ROOT / "lib"):
            result.append(other)
    return result


def main() -> None:
    sources = {p.resolve(): p.read_text(encoding="utf-8") for p in (ROOT / "lib").rglob("*.dart")}
    imports = {p: imported_files(p, s) for p, s in sources.items()}
    records = []
    for page in sorted((ROOT / "lib/features").rglob("*.dart")):
        if not (page.name.endswith("_page.dart") or page.name.endswith("_pages.dart")):
            continue
        page = page.resolve()
        seen: set[Path] = set()
        pending = [page]
        while pending:
            current = pending.pop()
            if current in seen:
                continue
            seen.add(current)
            pending.extend(imports.get(current, []))
        source = sources[page]
        records.append({
            "source": page.relative_to(ROOT).as_posix(),
            "sha256": hashlib.sha256(page.read_bytes()).hexdigest(),
            "module": page.relative_to(ROOT / "lib/features").parts[0],
            "appDensity": "inherited from UtenApp > UtenControlTheme",
            "reachableSharedImports": [key for key, value in SHARED.items() if (ROOT / value).resolve() in seen],
            "floatingActionDeclarations": len(re.findall(r"\bfloatingActionButton\s*:", source)),
            "fixedBottomDeclarations": len(re.findall(r"\b(?:bottomNavigationBar|persistentFooterButtons)\s*:", source)),
            "evidenceKind": "source inventory; interaction coverage listed separately in review receipt",
        })
    result = {
        "classification": "frontend presentation only; no server or API contract change",
        "platforms": {
            "web/flutter": "compact density below 840 window logical pixels; full-size desktop retained",
            "desktop/flutter": "same shared callers; desktop branches retained and regressed",
            "windows/wpf_legacy": "native desktop candidate; no mobile/tablet distribution or capsule shell; no new support claim",
        },
        "pageSourceCount": len(records),
        "sharedSourceHashes": {name: hashlib.sha256((ROOT / file).read_bytes()).hexdigest() for name, file in SHARED.items()},
        "pages": records,
    }
    DEST.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(f"Inventoried {len(records)} page sources -> {DEST.relative_to(ROOT).as_posix()}")


if __name__ == "__main__":
    main()
