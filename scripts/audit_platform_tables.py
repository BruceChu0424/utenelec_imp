#!/usr/bin/env python3
"""Inventory actual Dart AST table invocations; never count comments, strings or constructors.

Run after Flutter dependencies are installed:
  python scripts/audit_platform_tables.py --write
  python scripts/audit_platform_tables.py --check
The companion Dart parser understands generic/named constructors and distinguishes PDF tables.
"""
from __future__ import annotations
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.parse import unquote, urlparse

ROOT = Path(__file__).resolve().parents[1]
JSON_PATH = ROOT / 'docs/99-项目治理/platform_table_inventory.json'
MD_PATH = ROOT / 'docs/99-项目治理/platform_table_inventory.md'
SHARED = {'MasterDataTableView', 'UtenEditableGrid', 'UtenRevisionTable'}
PARAMS = ('tableKey','prefKey','platformScope','resourceScope','businessScope','scope','resource','tableScope',
          'columns','items','rows','controller','idOf','rowKeyOf','rowWidgetKeyOf','recordIdOf','resourceIdOf',
          'onAddColumn','initialColumnOrder','initialHiddenColumnKeys','onColumnSettingsChanged')
MODES = {
 'business_list': 'editable_reference_fields_only_after_explicit_resource_registration',
 'editable_detail': 'draft_reference_fields; authoritative_amounts_only_through_registered_business_save',
 'readonly_history': 'saved_snapshot_or_readonly_reference_fields; never_recalculate_posted_facts',
 'selector': 'column_preferences_and_authorized_reference_fields; no_implicit_master_write',
 'technical_monitor': 'column_preferences_and_display_calculations_only',
 'report': 'column_preferences_and_display_calculations; no_row_values_without_stable_identity',
 'print': 'fixed_print_layout; propagate_selected_business_columns_at_export_boundary',
 'shared_renderer': 'shared_implementation; caller_registry_and_row_identity_still_required',
 'source_file_preview': 'immutable_uploaded_source_preview; preserve_original_cells_and_attachment_access',
}

PRINT_BOUNDARIES = [
    {'scope': 'common_preview_pdf', 'policy': 'current_table_projection',
     'paths': ['lib/components/print/uten_print_preview.dart'],
     'reason': 'Common preview and PDF consume the same stable-key projection and authorized values; missing field bindings fail visibly.'},
    {'scope': 'expense_claim_items', 'policy': 'current_table_projection_with_frozen_history',
     'paths': ['lib/features/expense/widgets/expense_claim_print.dart'],
     'members': ['expensePrintItemsTable', '_itemsTable', '_pdfItemsTable'],
     'reason': 'Only reimbursement detail columns follow expense.claim.items. Submitted items use their own saved platformFields; absent legacy fields remain blank.'},
    {'scope': 'expense_fixed_sections', 'policy': 'purpose_specific_document',
     'paths': ['lib/features/expense/widgets/expense_claim_print.dart'],
     'reason': 'Payment evidence, company/header metadata, signature fields and approval history retain their document meaning and are not the current detail table.'},
    {'scope': 'manufacturing_documents_and_labels', 'policy': 'purpose_specific_document',
     'paths': ['lib/features/basic_data/widgets/goods_bom_preview.dart',
               'lib/features/production/widgets/production_execution_card_print_preview.dart',
               'lib/features/production/pages/production_plan_summary_sheet_page.dart',
               'lib/features/warehouse/pages/shelf_label_page.dart'],
     'reason': 'BOM manufacturing sheets, execution cards with task/material instructions, plan summary sheets and shelf labels are dedicated production documents, not copies of the surrounding workbench list.'},
    {'scope': 'payroll_slip', 'policy': 'purpose_specific_document',
     'paths': ['lib/features/payroll/pages/payroll_slip_detail_page.dart'],
     'serverRenderer': 'PayrollPdfService.render',
     'reason': 'The official payroll statement preserves payable components and signature fields. Payroll list preferences do not rewrite this issued document.'},
    {'scope': 'source_attachments', 'policy': 'immutable_source_preview',
     'reason': 'Uploaded CSV/PDF/images and source attachments keep original cells and access controls; business column preferences do not rewrite original evidence.'},
]

def print_policy(call: dict) -> str | None:
    path, member = call['path'], call.get('ownerMember')
    if path == 'lib/components/print/uten_print_preview.dart':
        return 'current_table_projection'
    if path == 'lib/features/expense/widgets/expense_claim_print.dart':
        return 'current_table_projection_with_frozen_history' if member in ('expensePrintItemsTable', '_itemsTable', '_pdfItemsTable') else 'purpose_specific_document'
    if call['component'] == 'UtenPrintTable':
        return 'print_data_binding_not_independent_renderer'
    if classify(call) == 'print':
        return 'purpose_specific_document'
    return None

def dart_executable(root: Path = ROOT) -> str:
    configured = shutil.which('dart')
    if configured: return configured
    config = root / '.dart_tool/package_config.json'
    if config.exists():
        package = json.loads(config.read_text(encoding='utf-8-sig'))
        flutter = unquote(urlparse(package.get('flutterRoot', '')).path)
        if re.match(r'^/[A-Za-z]:/', flutter): flutter = flutter[1:]
        for suffix in ('bin/cache/dart-sdk/bin/dart.exe', 'bin/cache/dart-sdk/bin/dart'):
            candidate = Path(flutter) / suffix
            if candidate.is_file(): return str(candidate)
    raise RuntimeError('Dart SDK unavailable; run flutter pub get and put dart on PATH')

def scan(root: Path = ROOT, source: str = 'lib') -> dict:
    command = [dart_executable(root), '--packages=' + str(root / '.dart_tool/package_config.json'),
               str(root / 'scripts/audit_platform_tables_ast.dart'), source]
    result = subprocess.run(command, cwd=root, capture_output=True, text=True, encoding='utf-8')
    if result.returncode: raise RuntimeError(result.stderr)
    raw = json.loads(result.stdout.lstrip('\ufeff'))
    if raw['parseErrorFiles']: raise RuntimeError('Dart parse errors: ' + ', '.join(raw['parseErrorFiles']))
    return raw

def classify(call: dict) -> str:
    path = call['path']; member = (call.get('ownerMember') or '').lower()
    if call['component'] == '_CsvBody' and path.endswith('attachment_preview_dialog.dart'): return 'source_file_preview'
    if call['qualifiedType'].startswith('pw.') or call['component'] == 'UtenPrintTable': return 'print'
    if any(s in path for s in ('/print/', '_print.dart', '_print_preview.dart', 'goods_bom_preview.dart', 'shelf_label_page.dart')): return 'print'
    if path.startswith('lib/components/') or path.endswith('master_data_table_view.dart'): return 'shared_renderer'
    if any(s in path for s in ('/admin/', 'server_status', 'audit_', 'health_check')): return 'technical_monitor'
    if any(s in path for s in ('picker', 'selector', 'import_dialog', 'import_review')): return 'selector'
    if call['component'] == 'UtenRevisionTable' or any(s in path for s in ('revision', '_history', '_review', '_detail', '_approval', 'records_page')): return 'readonly_history'
    if call['component'] == 'UtenEditableGrid': return 'editable_detail'
    if any(s in path for s in ('report_page', 'report_table', 'statement_page', 'ledger', 'overview_page')): return 'report'
    if any(s in member for s in ('review', 'history', 'revision', 'detail')): return 'readonly_history'
    return 'business_list'

def row_identity(call: dict) -> dict:
    args = call['arguments']
    expressions = {key: args[key] for key in ('recordIdOf','resourceIdOf','idOf','rowKeyOf','rowWidgetKeyOf') if key in args}
    bad = any(re.search(r'\bindex\b|hashCode|identityHashCode|toString\(\)', value) for value in expressions.values())
    if expressions:
        return {'status': 'requires_manual_stability_review' if bad else 'explicit_expression_requires_domain_verification', 'expressions': expressions}
    if call['component'] == 'UtenEditableGrid':
        return {'status': 'controller_rows_have_no_shared_persistent_id_contract', 'expressions': {}, 'controller': args.get('controller')}
    return {'status': 'not_declared_at_call_site', 'expressions': {}}

def fields(call: dict) -> tuple[list, str]:
    definitions = call.get('fileColumns', [])
    direct = [c for c in definitions if call['line'] <= c['line'] <= call['endLine']]
    if direct: selected, source = direct, 'inline_column_definitions'
    else:
        expression = call['arguments'].get('columns', '')
        names = set(re.findall(r'\b\w+\b', expression))
        selected = [c for c in definitions if c['ownerClass'] == call['ownerClass'] and c['ownerMember'] in names]
        source = 'same_class_column_helper' if selected else 'external_or_dynamic_column_source_requires_registration'
    result = []
    for column in selected:
        args = column['arguments']
        result.append({'key': args.get('key'), 'label': args.get('label'), 'type': args.get('type'),
                       'value': args.get('value') or args.get('textOf') or args.get('frozenTextOf'),
                       'sourceLine': column['line'], 'editable': 'cellBuilder' in args and call['component'] == 'UtenEditableGrid'})
    return result, source

def build(raw: dict) -> dict:
    calls = raw['calls']; ordinals = Counter(); path_counts = Counter(c['path'] for c in calls)
    entries = []
    for call in calls:
        category = classify(call)
        kind = 'pdf_document_table' if call['qualifiedType'].startswith('pw.') else ('print_data_specification' if call['component'] == 'UtenPrintTable' else 'flutter_table')
        key = (call['path'], call['ownerClass'], call['ownerMember'], call['component'])
        ordinals[key] += 1
        base, resolution = fields(call)
        facts = ' '.join(str(c.get(k) or '') for c in base for k in ('key','label','type','value'))
        if not base: facts = str(call['arguments'].get('columns', ''))
        money = bool(re.search(r'amount|price|money|fee|cost|balance|金额|单价|费用|余额', facts, re.I))
        quantity = bool(re.search(r'qty|quantity|weight|数量|重量|库存', facts, re.I))
        args = {k:v for k,v in call['arguments'].items() if k in PARAMS}
        identities = row_identity(call)
        gaps = []
        if kind == 'flutter_table' and category not in ('print','shared_renderer','source_file_preview'):
            if call['component'] not in SHARED: gaps.append('native_renderer_requires_shared_adapter')
            if not args.get('tableKey'): gaps.append('stable_table_key_not_declared')
            if identities['status'] == 'not_declared_at_call_site' or 'persistent_id' in identities['status']: gaps.append('stable_domain_row_identity_not_declared')
            if not any(k in args for k in ('platformScope','resourceScope','businessScope','tableScope')): gaps.append('authorized_resource_binding_not_declared_at_call_site')
            if resolution.startswith('external'): gaps.append('base_field_binding_not_resolved_by_static_inventory')
            gaps.append('end_to_end_persistence_permission_history_export_evidence_required')
        entries.append({'id': '::'.join(str(v or '<top>') for v in key) + f'#{ordinals[key]}',
            'path': call['path'], 'line': call['line'], 'endLine': call['endLine'], 'component':call['component'],
            'qualifiedType':call['qualifiedType'], 'kind':kind, 'ownerClass':call['ownerClass'], 'ownerMember':call['ownerMember'],
            'callsInFile':path_counts[call['path']], 'category':category, 'categoryEvidence':'path_and_enclosing_method_policy',
            'arguments':args, 'prefKey':args.get('prefKey'), 'scope':next((args[k] for k in ('platformScope','resourceScope','businessScope','tableScope') if k in args), None),
            'preferenceAndScopeEvidence':call.get('filePreferences', []), 'rowIdentity':identities,
            'baseFields':base, 'baseFieldsResolution':resolution,
            'involvesMoney':money if base else None, 'involvesQuantity':quantity if base else None,
            'numericEvidence': 'column_definitions' if base else 'unresolved_not_assumed_safe',
            'recommendedMode':MODES[category], 'sharedRenderer':call['component'] in SHARED,
            'coverageStatus':'immutable_source_preview' if category=='source_file_preview' else ('fixed_print_boundary' if category=='print' else ('shared_infrastructure_only' if category=='shared_renderer' else 'requires_end_to_end_acceptance')),
            'printProjectionPolicy':print_policy(call), 'coverageGaps':gaps})
    ui = [e for e in entries if e['kind']=='flutter_table']
    return {'schemaVersion':1, 'sourceRoot':'lib', 'generator':'scripts/audit_platform_tables.py + Dart analyzer AST',
        'sourceFileCount':raw['sourceFileCount'], 'parseErrorFiles':raw['parseErrorFiles'],
        'countMeaning':'Source invocation sites, not route count or runtime table instances. Shared wrappers count at their renderer call; PDF and print data are separate.',
        'printBoundaries':PRINT_BOUNDARIES,
        'completionCriteria':['stable_table_key_and_authoritative_record_id','server_scope_registered_with_existing_object_permissions',
            'typed_field_definitions_and_values_persist_on_authorized_business_save','approved_and_history_read_saved_snapshots',
            'derived_fields_do_not_mutate_quantity_money_ledger_or_source_identity','search_reuse_and_explicit_user_choice_preserved',
            'edit_detail_review_export_share_same_field_projection','tests_cover_roundtrip_scope_denial_history_and_new_columns'],
        'summary':{'allCalls':len(entries),'filesWithCalls':len(path_counts),'flutterCalls':len(ui),
            'byComponent':dict(sorted(Counter(e['component'] for e in entries).items())),
            'byKind':dict(sorted(Counter(e['kind'] for e in entries).items())),
            'byCategory':dict(sorted(Counter(e['category'] for e in entries).items())),
            'unsharedBusinessFlutterCalls':sum(e['component'] not in SHARED and e['category'] not in ('print','shared_renderer','source_file_preview') for e in ui)},
        'tables':entries}

def markdown(data: dict) -> str:
    summary=data['summary']
    lines=['# Flutter 全平台表格库存', '', '> 自动生成：`python scripts/audit_platform_tables.py --write`；CI/本地核对：`--check`。', '',
        f"扫描 `lib/` {data['sourceFileCount']} 个 Dart 源文件，记录 {summary['allCalls']} 个调用点（{summary['filesWithCalls']} 个文件）。真实 Flutter 表格 {summary['flutterCalls']} 处。", '',
        '这里统计实际 AST 调用（包括已核对的原件 CSV 自绘表格 `_CsvBody`），排除注释、字符串与构造器声明。`pw.Table` 是 PDF 内容；`UtenPrintTable` 是打印数据规格，均不计入交互表格。调用点不等于页面数：共享 wrapper 的实际渲染点记录一次。', '',
        '**接入共享组件不代表业务功能完成。** 每个资源仍须有稳定业务行 ID、后端对象权限、持久化与并发校验、只读历史快照、导出及审批一致性证据。库存保守标注未确认项，不把 `hashCode`、行下标或显示文本当持久化身份。', '',
        '原件 CSV 预览遵守附件原件不可覆盖规则，不把业务表头投影写回上传原件。分类由路径及所在方法的显式规则生成；动态列及跨文件工厂无法由本清单证明字段绑定时标为 unresolved，必须由页面注册或人工复核补足。`preferenceAndScopeEvidence` 只是同文件证据，不冒充当前表格已绑定。', '',
        '| 组件 | 调用点 |', '|---|---:|']
    lines += [f'| {name} | {count} |' for name,count in summary['byComponent'].items()]
    pdfs = [e for e in data['tables'] if e['kind']=='pdf_document_table']
    projected_pdf = sum((e['printProjectionPolicy'] or '').startswith('current_table_projection') for e in pdfs)
    lines += ['', '## 打印与原件边界', '',
        f"当前 AST 中有 {len(pdfs)} 处 PDF 表格调用：其中 {projected_pdf} 处是随当前业务表头投影的公共打印或报销明细，其余保留专用凭证版式。调用数量不代表逐页面人工验收，也不表示所有打印件都套用列表表头。", '',
        '- 公共预览/PDF及报销自定义打印的明细使用同一可见列、顺序、标题及宽度。计算字段读取服务端定义和原始数值；缺少绑定会明确失败。报销审核历史只读取该次提交快照。',
        '- 报销票据、付款事实、签名及流转历史保留；生产任务卡的任务/BOM材料说明、BOM生产用表、生产计划汇总件、货架标签属于专用业务输出，不是当前工作台主表的普通导出。',
        '- 正式工资条由服务端生成，是固定发放凭证；工资列表的表头不修改其原始工资项目或签名区。',
        '- 上传原件的 CSV/PDF/图片及源附件仍保留原貌及附件权限。`printBoundaries` 与每个调用的 `printProjectionPolicy` 记录这一区分。']
    lines += ['', '## 仍使用原生组件的业务表格', '', '| 路径 | 方法 | 组件 | 推荐模式 |', '|---|---|---|---|']
    for e in data['tables']:
        if e['kind']=='flutter_table' and not e['sharedRenderer'] and e['category'] not in ('print','shared_renderer','source_file_preview'):
            lines.append(f"| `{e['path']}:{e['line']}` | `{e['ownerMember']}` | {e['component']} | {e['recommendedMode']} |")
    lines += ['', '## 全部调用点', '', '| 路径 | 组件 | 分类 | 行身份证据 | 表格键 |', '|---|---|---|---|---|']
    for e in data['tables']:
        rowid='; '.join(e['rowIdentity']['expressions'].values()) or e['rowIdentity']['status']
        rowid=rowid.replace('|','\\|')
        lines.append(f"| `{e['path']}:{e['line']}` | {e['qualifiedType']} | {e['category']} | {rowid} | {e['arguments'].get('tableKey','未声明')} |")
    lines += ['', '逐列字段、偏好/scopes 证据、金额/数量判据及覆盖缺口以同目录 `platform_table_inventory.json` 为准。', '']
    return '\n'.join(lines)

def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write',action='store_true'); parser.add_argument('--check',action='store_true')
    parser.add_argument('--raw-json',type=Path,help='Reuse one captured AST snapshot while authoring; CI should rescan')
    args=parser.parse_args()
    raw=json.loads(args.raw_json.read_text(encoding='utf-8-sig')) if args.raw_json else scan()
    data=build(raw); text=json.dumps(data,ensure_ascii=False,indent=2)+'\n'; md=markdown(data)
    if args.write:
        JSON_PATH.parent.mkdir(parents=True,exist_ok=True); JSON_PATH.write_text(text,encoding='utf-8'); MD_PATH.write_text(md,encoding='utf-8')
    if args.check:
        actual=JSON_PATH.read_text(encoding='utf-8') if JSON_PATH.exists() else ''
        actual_md=MD_PATH.read_text(encoding='utf-8') if MD_PATH.exists() else ''
        if actual != text or actual_md != md:
            print('Platform table inventory is stale. Run python scripts/audit_platform_tables.py --write.',file=sys.stderr)
            return 1
    print(json.dumps(data['summary'],ensure_ascii=False))
    return 0
if __name__=='__main__': raise SystemExit(main())
