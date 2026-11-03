"""Current category-read inventory; lexical hits are not interaction acceptance."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'docs/99-项目治理/全平台整改交接/evidence/category-prefetch-20261103'
OUTPUT = DEST / 'coverage.json'


def record(path: Path, text: str, markers: tuple[str, ...]) -> dict:
    return {
        'source': path.relative_to(ROOT).as_posix(),
        'sha256': hashlib.sha256(text.encode('utf-8')).hexdigest(),
        'lines': [i for i, line in enumerate(text.splitlines(), 1)
                  if any(marker in line for marker in markers)],
    }


def inventory() -> dict:
    categories, preparation, counts = [], [], []
    category_markers = ('UtenFilterToolbar', 'UtenFilterSegment', 'WarehouseTaskCenterScaffold')
    prepare_markers = ('PreparedPageRead', 'PagePreparationCoordinator', 'pagePreparationBudgetProvider')
    count_markers = ('badgeFactOrNullProvider', 'badgeSummaryProvider',
                     'warehouseTaskFactOrNullProvider', 'effectiveDocumentStatusCountsProvider')
    for path in sorted((ROOT / 'lib').rglob('*.dart')):
        text = path.read_text(encoding='utf-8-sig')
        if 'features' in path.parts and any(marker in text for marker in category_markers):
            categories.append(record(path, text, category_markers))
        if any(marker in text for marker in prepare_markers):
            preparation.append(record(path, text, prepare_markers))
        if 'features' in path.parts and any(marker in text for marker in count_markers):
            counts.append(record(path, text, count_markers))
    registry = json.loads((ROOT / 'clients/windows_legacy/progress/work-items.json').read_text(encoding='utf-8-sig'))
    category_sources = {item['source'] for item in categories}
    return {
        'schemaVersion': 1,
        'baselineCommit': '54475dc638ec94ad4ff38ebad0e860c70bca07d9',
        'interpretation': 'Source candidates and current hashes only. Semantic disposition and test scope are in the module reviews; no hit implies runtime acceptance.',
        'hashNormalization': 'UTF-8 text without BOM, CRLF normalized to LF; source line numbers follow the same text.',
        'publicEntries': {
            'completeFirstPageHandoff': 'lib/shared/paging/prepared_page_read.dart',
            'categoryCoordinator': 'lib/shared/paging/page_preparation_coordinator.dart',
            'appPhysicalBudget': 'lib/shared/paging/page_preparation_budget_provider.dart',
            'smallCategorySnapshots': 'lib/shared/paging/scoped_category_read.dart',
            'documentCounts': 'lib/shared/providers/document_status_counts_provider.dart',
        },
        'categorySources': categories,
        'preparationSources': preparation,
        'sharedCountSources': counts,
        'moduleReviews': [record(path, path.read_text(encoding='utf-8-sig'), ())
                          for path in sorted(DEST.glob('*-review.json'))],
        'nativeCategoryPackages': [
            {'id': task['id'], 'source': task['businessSource'], 'status': task['status'],
             'interpretation': 'Existing state retained; a Dart fix or a source hit does not migrate a native workflow.'}
            for task in registry['tasks'] if task.get('businessSource') in category_sources
        ],
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--write', action='store_true')
    group.add_argument('--check', action='store_true')
    args = parser.parse_args()
    result = inventory()
    rendered = json.dumps(result, ensure_ascii=False, indent=2) + '\n'
    if args.check and (not OUTPUT.is_file() or OUTPUT.read_text(encoding='utf-8') != rendered):
        raise SystemExit('Current category prefetch inventory is stale; run --write.')
    if args.write:
        DEST.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(rendered, encoding='utf-8', newline='\n')
    print(json.dumps({key: len(result[key]) for key in (
        'categorySources', 'preparationSources', 'sharedCountSources', 'moduleReviews', 'nativeCategoryPackages')}, ensure_ascii=False))
