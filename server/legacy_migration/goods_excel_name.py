"""Separate the reviewed product-list export's metadata from its product name.

This applies only at that Excel source boundary. User-entered names, ordinary
goods imports and historical document snapshots are never rewritten by it.
"""


def excel_product_name_evidence(name: str, *, color: str = "", series: str = "",
                                legacy_name: str | None = None,
                                color_tokens: set[str] | frozenset[str] = frozenset()) -> tuple[str, str | None]:
    """Separate a terminal export decoration only with independent source facts.

    Parentheses, title brackets elsewhere, unmatched metadata, model text and
    an empty base name remain untouched. Empty/stale metadata needs the exact
    old base and, for stale colors, a real dictionary token. The original
    workbook stays archived; reviewed exceptions use a separate explicit input.
    """
    suffix = f"《{color}\\{series}》"
    if (color or series) and name.endswith(suffix):
        base = name[:-len(suffix)].rstrip()
        if base:
            return base, "exact_excel_color_series_decoration"
    if legacy_name is not None:
        base = legacy_name.strip()
        if base and not color and not series and name == base + "《\\》":
            return base, "legacy_corroborated_empty_export_decoration"
        for token in color_tokens:
            if base and token and series and name == base + f"《{token}\\{series}》":
                return base, "legacy_and_color_dictionary_corroborated_export_decoration"
    return name, None


def excel_product_name(name: str, *, color: str = "", series: str = "",
                       legacy_name: str | None = None,
                       color_tokens: set[str] | frozenset[str] = frozenset()) -> str:
    return excel_product_name_evidence(name, color=color, series=series,
                                       legacy_name=legacy_name, color_tokens=color_tokens)[0]


def reviewed_excel_product_name(decision: dict, *, code: str, legacy_id: str,
                                legacy_name: str, name: str, color: str, series: str,
                                source_file: str, source_sheet: str, source_row: int,
                                company_goods_id: str | None = None) -> tuple[str, str]:
    """Apply an explicit reviewed source decision, never a general bracket rule."""
    expected = {"code": code, "legacy_id": str(legacy_id), "legacy_name": legacy_name,
                "source_name": name, "color": color, "series": series,
                "source_file": source_file, "source_sheet": source_sheet, "source_row": source_row}
    if (decision.get("action") != "SEPARATE_REVIEWED_EXCEL_DISPLAY_SUFFIX"
            or any(str(decision.get(key)) != str(value) for key, value in expected.items())
            or not legacy_name.strip() or decision.get("new_name") != legacy_name.strip()
            or decision.get("new_name") == name or not decision.get("review_id")
            or (company_goods_id is not None and decision.get("company_goods_id") != company_goods_id)):
        raise ValueError("Reviewed goods-name source facts changed; refusing the decision")
    return decision["new_name"], "reviewed_source_name_decision:" + decision["review_id"]
