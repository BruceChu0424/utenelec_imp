"""Run the shared retained-layout regression in isolated repository-owned tools.

Widget tests use controlled transport; this does not replace actual Web/Windows
HTTP acceptance. Existing output directories are never reused or overwritten.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

TEST_FILES = (
    'test/independent/default_collapsing_tooltip_reparent_test.dart',
    'test/independent/overflow_semantics_menu_reparent_test.dart',
    'test/independent/minimal_split_tooltip_reparent_test.dart',
    'test/independent/minimal_hierarchy_height_tooltip_test.dart',
    'test/independent/minimal_compact_header_width_test.dart',
    'test/independent/retained_pane_resize_stress_test.dart',
    'test/uten_split_view_test.dart',
    'test/uten_split_view_controlled_width_test.dart',
    'test/shared/widgets/uten_hierarchy_short_viewport_test.dart',
    'test/uten_collapsing_header_scroll_view_test.dart',
    'test/uten_collapsing_header_touch_test.dart',
    'test/uten_collapsing_header_mode_transition_test.dart',
    'test/uten_collapsing_header_primary_isolation_test.dart',
    'test/uten_collapsing_header_scroll_relayout_test.dart',
    'test/uten_collapsing_header_semantics_transition_test.dart',
    'test/components/uten_unified_page_layout_test.dart',
    'test/components/uten_content_container_test.dart',
    'test/master_data_table_mutable_row_refresh_test.dart',
    'test/master_data_table_width_cursor_test.dart',
    'test/features/finance/finance_doc_detail_collapsing_header_test.dart',
    'test/features/warehouse/warehouse_detail_collapsing_header_test.dart',
    'test/features/production/pages/production_daily_report_detail_collapsing_header_test.dart',
    'test/features/subcontract/subcontract_doc_detail_collapsing_header_test.dart',
    'test/features/sales/pages/sales_doc_detail_collapsing_header_test.dart',
    'test/features/basic_data/pages/master_menu_scheduler_probe_test.dart',
    'test/features/basic_data/pages/master_menu_column_settings_probe_test.dart',
    'test/components/uten_page_scrollbar_host_test.dart',
    'test/components/uten_page_scrollbar_signal_test.dart',
    'test/components/uten_page_scrollbar_coverage_test.dart',
    'test/components/uten_page_scrollbar_compact_rail_test.dart',
    'test/core/router/entry_page_scrollbar_test.dart',
    'test/components/layout/uten_fit_or_compact_test.dart',
    'test/uten_sticky_wheel_gate_test.dart',
)
ANALYZE_FILES = (
    'lib/components/layout/uten_collapsing_header_scroll_view.dart',
    'lib/components/layout/uten_page_scrollbar_host.dart',
    'lib/features/basic_data/widgets/master_data_table_view.dart',
    'test/support/collapsing_header_harness.dart',
    'test/uten_collapsing_header_scroll_relayout_test.dart',
    'test/uten_collapsing_header_scroll_view_test.dart',
    'test/uten_collapsing_header_semantics_transition_test.dart',
    'test/independent/default_collapsing_tooltip_reparent_test.dart',
    'test/independent/overflow_semantics_menu_reparent_test.dart',
    'test/features/basic_data/pages/master_menu_column_settings_probe_test.dart',
    'test/features/basic_data/pages/master_menu_scheduler_probe_test.dart',
    'test/components/uten_page_scrollbar_signal_test.dart',
)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    output = args.output.resolve()
    if not output.is_relative_to(root) or output == root:
        raise SystemExit('Output must be a new directory inside the selected worktree')
    output.mkdir(parents=True, exist_ok=False)
    private = output / 'private'
    private.mkdir()
    temporary = private / 'tmp'
    temporary.mkdir()
    os.environ.update(TMP=str(temporary), TEMP=str(temporary),
                      FLUTTER_SUPPRESS_ANALYTICS='true', PUB_HOSTED_URL='https://pub.dev')
    sys.path.insert(0, str(root / '.github/scripts'))
    import isolated_flutter_web_tools as tooling
    flutter = shutil.which('flutter')
    if not flutter:
        raise SystemExit('Flutter is not available')
    raw = subprocess.check_output([flutter, '--version', '--machine'], cwd=root)
    version = json.loads(raw[raw.index(b'{'):])
    selected = tuple(dict.fromkeys(TEST_FILES + ANALYZE_FILES))
    for path in selected:
        if not (root / path).is_file():
            raise SystemExit('Required regression source is missing: ' + path)
    subprocess.run(['git', 'diff', '--exit-code', 'HEAD', '--', *selected], cwd=root,
                   check=True, stdout=subprocess.DEVNULL)
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root).decode().strip()
    receipt = {'source': source, 'controlledWidgetTransport': True,
               'realHttpAccepted': False,
               'files': {path: digest(root/path) for path in selected}, 'runs': []}
    with (output/'prepare.log').open('wb') as log:
        prefix, proof, environment = tooling.prepare(flutter, version, private/'tools', log, log)
    try:
        for name, arguments in [
            ('analyze', ['analyze', '--no-pub', *ANALYZE_FILES]),
            ('regression', ['test', '--no-pub', '--reporter=expanded', '--timeout=60s', *TEST_FILES]),
        ]:
            command = list(prefix) + arguments
            with (output/(name+'.log')).open('wb') as log:
                code = subprocess.run(command, cwd=root, env=environment,
                                      stdout=log, stderr=log).returncode
            receipt['runs'].append({'name': name, 'command': command, 'exitCode': code})
    finally:
        tooling.confirm_sdk_unchanged(proof)
        receipt['sdk'] = proof
        receipt['afterSource'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root).decode().strip()
        receipt['sourceFilesUnchanged'] = all(digest(root/path) == old for path, old in receipt['files'].items())
        (output/'result.json').write_text(json.dumps(receipt, indent=2), encoding='utf8')
    return 0 if receipt['sourceFilesUnchanged'] and receipt['afterSource'] == source and all(run['exitCode'] == 0 for run in receipt['runs']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
