"""Rebuild the search source inventory. A lexical candidate is never runtime acceptance."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / 'docs/99-项目治理/全平台整改交接/evidence/search-loading-20261103'
OUTPUT = DEST / 'source-inventory.json'
SCOPES = (
    ('flutter', 'lib', {'.dart'}, r'UtenSearchBar|keywordSearch|KeywordSearch|(?:search|keyword)\s*:|\bsearch(?:Columns|Context|CategoryIds)?\(|onChanged:[^\n]*(?:search|query|keyword)|\.contains\(_?(?:search|query|keyword)\b'),
    ('server', 'server/src/main/java', {'.java'}, r'KeywordSearch|NameRefKeyword|ColumnSearch|\bI?LIKE\b|@RequestParam[^\n]*(?:search|keyword)|\bfind\w*(?:Containing|StartingWith|EndingWith|ContainsIgnoreCase)\w*\('),
    ('website', 'website', {'.ts', '.tsx'}, r'searchParams|SearchInput|searchTerms|productSearch|keyword|\bcontains\s*:'),
    ('wpf', 'clients/windows_legacy', {'.cs', '.xaml'}, r'SearchText|SearchAsync|SearchBox|SearchQuery|searchText|keyword|ApplySearch'),
)
EXCLUDED = {'node_modules', '.next', '.dart_tool', 'bin', 'obj', 'build', 'TestResults'}


def inventory() -> dict:
    candidates = []
    for platform, directory, suffixes, pattern in SCOPES:
        matcher = re.compile(pattern, re.I if platform == 'server' else 0)
        paths = []
        for parent, directories, files in os.walk(ROOT / directory, followlinks=False):
            directories[:] = sorted(name for name in directories if name not in EXCLUDED)
            paths.extend(Path(parent) / name for name in files if Path(name).suffix in suffixes)
        for path in sorted(paths):
            if path.name.endswith('.d.ts'):
                continue  # Type declarations, including task-local Prisma output, are not runtime search callers.
            source = path.read_text(encoding='utf-8-sig')
            lines = [i for i, line in enumerate(source.splitlines(), 1) if matcher.search(line)]
            if lines:
                candidates.append({
                    'platform': platform,
                    'source': path.relative_to(ROOT).as_posix(),
                    'sha256': hashlib.sha256(source.encode('utf-8')).hexdigest(),
                    'lines': lines,
                })
    return {
        'schemaVersion': 1,
        'baselineCommit': '8937e02d2f9b4ae1f5a4ff63ad79673cbd3ad149',
        'integrationBaseCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'scope': 'Search only; unrelated loading, active projections, physical archive and publishing are excluded.',
        'interpretation': 'Discovery candidates with current source fingerprints. Dispositions and test limits belong to platform reviews; hits are not pages or accepted workflows.',
        'normalization': 'UTF-8 without BOM, newlines normalized to LF',
        'platformCounts': {platform: sum(row['platform'] == platform for row in candidates) for platform, *_ in SCOPES},
        'candidates': candidates,
        'reviewFiles': [path.name for path in sorted(DEST.glob('*-review.json'))],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--write', action='store_true')
    mode.add_argument('--check', action='store_true')
    args = parser.parse_args()
    value = inventory()
    rendered = json.dumps(value, ensure_ascii=False, indent=2) + '\n'
    if args.write:
        DEST.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_text(rendered, encoding='utf-8')
    elif not OUTPUT.is_file() or OUTPUT.read_text(encoding='utf-8') != rendered:
        raise SystemExit('Search discovery inventory is stale. Rebuild with --write after reviewing source changes.')
    print(json.dumps({'result': 'PASS', 'platformCounts': value['platformCounts'],
                      'reviewFiles': value['reviewFiles'], 'runtimeAcceptance': False}, ensure_ascii=True))


if __name__ == '__main__':
    main()
