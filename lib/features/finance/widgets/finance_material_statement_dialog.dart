import '../shared/finance_workbench_panel.dart';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_action_overflow.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/layout/uten_segment_row.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/complete_paged_snapshot.dart';
import '../../../shared/paging/read_view_activity.dart';
import '../../../shared/paging/scoped_paged_read.dart'
    show pagedReadAccessDenied;
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../config/finance_requirement_names.dart';
import 'finance_source_table.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import 'finance_chart_dialog.dart';
import 'finance_auxiliary_dialog.dart';
import 'finance_entry_file_picker.dart';
import 'finance_editable_grid_window.dart';
import '../../../shared/drafts/form_draft_store.dart';

part 'finance_material_statement_editor.dart';
part 'finance_material_statement_pickers.dart';
part 'finance_material_statement_compare.dart';

const _materialBase = '/finance/material-statements';
const _materialKinds = <String, String>{
  'CONTEXT': '分组资料',
  'GOODS': '材料／产品对应',
  'NATIVE_PARTY': '来源单位对应',
  'UNIT': '单位换算依据',
  'OPENING': '期初重量',
  'WEIGHT': '实称／实点',
  'SOURCE_RELATION': '逐源归入本组',
  'COVERAGE': '来源范围核对',
  'FEE': '加工货款归属',
  'ZERO': '明确免加工款',
  'SIDEBAR': '原隐藏旁算资料',
  'CLOSE': '撤销本次维护',
};
const _sourceKinds = <String, String>{
  'PURCHASE_RECEIPT_LINE': '采购入库',
  'SUBCONTRACT_MATERIAL_ISSUE_LINE': '委外材料出仓单',
  'SUBCONTRACT_MATERIAL_RETURN_LINE': '委外材料退货单',
  'STOCK_OTHER_OUT_LINE': '其他出库单',
  'SALES_OTHER_SHIPMENT_LINE': '销售其他出库单',
};
const _flowRoles = <String, String>{
  'INBOUND': '来料重量',
  'MATERIAL_OUT': '材料发出重量（不计成品数量）',
  'FINISHED_OUT': '其他出库重量、成品数量及加工款',
  'MATERIAL_RETURN': '材料退回重量（不减成品数量）',
};
const _states = <String, String>{
  'DRAFT': '草稿',
  'SUBMITTED': '待另一财务审核',
  'APPROVED': '已审核',
  'REJECTED': '已退回',
  'WITHDRAWN': '已撤回',
};
Map<String, dynamic> _mm(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : {};
List<Map<String, dynamic>> _ml(Object? v) => [
  if (v is List)
    for (final item in v)
      if (item is Map) Map<String, dynamic>.from(item),
];
int _mi(Object? v) =>
    v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
String _id(Map<String, dynamic>? v) =>
    (v?['id'] ?? v?['contextId'] ?? '').toString();

// The material APIs use ordinary page envelopes but different source identities.
// Only this projection differs; complete collection/retirement stays public.
Future<Map<String, dynamic>> _readMaterialPages({
  required bool Function() current,
  required Future<Map<String, dynamic>> Function(int, int) fetch,
  Object? Function(Map<String, dynamic>)? identity,
  void Function(List<Map<String, dynamic>> items)? onRows,
}) async {
  Map<String, dynamic> first = {};
  final result = await loadCompletePagedResult<Map<String, dynamic>>(
    isCurrent: current,
    idOf: identity ?? _id,
    loadPage: (page, size) async {
      final value = await fetch(page, size);
      if (page == 1) first = value;
      return PagedResult.fromJsonResponsive(value, (row) => row);
    },
    onProgressiveBatch: onRows == null
        ? null
        : (partial) => onRows(partial.items),
  );
  return {
    ...first,
    'items': result.items,
    'page': 1,
    'size': result.size,
    'total': result.total,
    'totalPages': result.totalPages,
  };
}

String _problem(Object e) => humanErrorMessage(e) ?? '资料未处理完成，原输入已保留';
Map<String, dynamic> _effective(Map<String, dynamic> row) {
  final saved = _mm(row['source_snapshot']);
  return _mm(saved['effectiveInput'] ?? row['input']);
}

Future<bool> showFinanceMaterialStatementDialog(
  BuildContext context, {
  String? initialContextId,
  String? initialEvidenceId,
  String? dateFrom,
  String? dateTo,
  String? resumeDraftId,
}) async =>
    await showFinanceWorkbenchPanel<bool>(
      context: context,
      builder: (_) => UtenDialogFrame(
        child: SizedBox(
          width: 1380,
          height: MediaQuery.sizeOf(context).height * .92,
          child: FinanceMaterialStatementSurface(
            initialContextId: initialContextId,
            initialEvidenceId: initialEvidenceId,
            dateFrom: dateFrom,
            dateTo: dateTo,
            resumeDraftId: resumeDraftId,
          ),
        ),
      ),
    ) ??
    false;

/// The ordinary financial shell stays the same. This workbench maintains only
/// explicit source relations and evidence; it never posts another stock or GL.
class FinanceMaterialStatementSurface extends ConsumerStatefulWidget {
  const FinanceMaterialStatementSurface({
    super.key,
    this.initialContextId,
    this.initialEvidenceId,
    this.dateFrom,
    this.dateTo,
    this.resumeDraftId,
  });
  final String? initialContextId,
      initialEvidenceId,
      dateFrom,
      dateTo,
      resumeDraftId;
  @override
  ConsumerState<FinanceMaterialStatementSurface> createState() =>
      _MaterialDirectory();
}

class _MaterialDirectory extends ConsumerState<FinanceMaterialStatementSurface>
    with ReadViewActivityMixin<FinanceMaterialStatementSurface> {
  @override
  Future<void> onReadViewResumed() async {
    if (_context == null) {
      await _load();
    } else {
      await _openContext(_id(_context), preserveSelection: true);
      if (_current && _rule != null) await _sourceLoad();
    }
  }

  final _search = TextEditingController(),
      _from = TextEditingController(),
      _to = TextEditingController();
  final _lookup = TextEditingController();
  List<Map<String, dynamic>> _contexts = [],
      _history = [],
      _sources = [],
      _rules = [];
  List<Map<String, dynamic>> _sidebar = [], _sideActual = [];
  bool _showSideActual = false;
  Map<String, dynamic>? _context, _rule;
  int _tab = 0, _read = 0;
  bool _busy = true, _retired = false, _changed = false, _readDenied = false;
  String? _error;
  late final bool Function() _owner;
  bool get _current => mounted && !_retired && _owner();
  bool _can(String permission) =>
      ref.read(authenticatedScopeProvider)?.readOnly == false &&
      ref.read(currentPermissionsProvider).contains(permission);
  @override
  void initState() {
    super.initState();
    _owner = captureReadOwner(ref);
    listenReadOwner(ref, () {
      if (mounted) {
        setState(() {
          _retired = true;
          _contexts = [];
          _history = [];
          _sources = [];
          _context = null;
        });
      }
    });
    final start = DateTime(DateTime.now().year, DateTime.now().month),
        end = DateTime(DateTime.now().year, DateTime.now().month + 1, 0);
    _from.text = widget.dateFrom ?? start.toIso8601String().substring(0, 10);
    _to.text = widget.dateTo ?? end.toIso8601String().substring(0, 10);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initial());
  }

  @override
  void dispose() {
    _search.dispose();
    _from.dispose();
    _to.dispose();
    _lookup.dispose();
    super.dispose();
  }

  Future<void> _initial() async {
    await _load();
    if (!_current) return;
    if (widget.initialContextId != null) {
      await _openContext(widget.initialContextId!);
    }
    if (!_current) return;
    if (widget.resumeDraftId != null) {
      await ref.read(formDraftsProvider.notifier).ready;
      if (!_current) return;
      if (!ref
          .read(formDraftsProvider)
          .any((draft) => draft.id == widget.resumeDraftId)) {
        setState(() => _error = '原草稿尚未找到，分组和原件没有改动，请从任务中心核对原账号及记录。');
        return;
      }
    }
    final saved = ref
        .read(formDraftsProvider)
        .where((d) => d.id == widget.resumeDraftId)
        .firstOrNull;
    if (saved?.data['mode'] == 'COMPARE') {
      await _compare(resumeDraftId: widget.resumeDraftId);
      return;
    }
    if (widget.resumeDraftId != null || widget.initialEvidenceId != null) {
      await _editor(
        evidenceId: widget.initialEvidenceId,
        resumeDraftId: widget.resumeDraftId,
      );
    }
  }

  void _readFailed(Object error) {
    _error = _problem(error);
    if (!pagedReadAccessDenied(error)) return;
    _readDenied =
        _context != null ||
        _contexts.isNotEmpty ||
        _history.isNotEmpty ||
        _sources.isNotEmpty;
    _contexts = [];
    _history = [];
    _sources = [];
    _rules = [];
    _sidebar = [];
    _sideActual = [];
    _context = null;
    _rule = null;
  }

  Future<void> _load() async {
    if (!_current) return;
    final generation = ++_read;
    var partialRows = false;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiClientProvider),
          scope = await api.captureRequestScope(
            isCurrent: () => _current && generation == _read,
          );
      final result = await readViewActivity.runRead(
        () => _current && generation == _read,
        () => scope.run(
          () => _readMaterialPages(
            current: () => _current && generation == _read && scope.isCurrent,
            fetch: (batch, size) => api.get(
              _materialBase,
              query: {'q': _search.text.trim(), 'page': batch, 'size': size},
            ),
            onRows: (items) {
              if (!_current || !scope.isCurrent || generation != _read) return;
              setState(() {
                _contexts = _ml(items);
                partialRows = true;
              });
            },
          ),
        ),
      );
      if (!_current || !scope.isCurrent || generation != _read) return;
      setState(() {
        _contexts = _ml(result['items']);
        partialRows = false;
        _error = null;
        _readDenied = false;
      });
    } catch (e) {
      if (isRetiredViewRead(e)) return;
      if (_current && generation == _read) {
        setState(() {
          // 逐批前缀不是完整结果：失败时整体下撤。
          if (partialRows) _contexts = [];
          _readFailed(e);
        });
      }
    } finally {
      if (_current && generation == _read) setState(() => _busy = false);
    }
  }

  Future<void> _openContext(String id, {bool preserveSelection = false}) async {
    if (!_current) return;
    final generation = ++_read;
    final oldRule = preserveSelection && _rule != null
        ? _rule!['evidenceId']
        : null;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiClientProvider),
          scope = await api.captureRequestScope(
            isCurrent: () => _current && generation == _read,
          );
      final loaded = await readViewActivity.runRead(
        () => _current && generation == _read,
        () => scope.run(() async {
          final context = await api.get('$_materialBase/$id');
          final history = await _readMaterialPages(
            current: () => _current && generation == _read && scope.isCurrent,
            fetch: (page, size) => api.get(
              '$_materialBase/evidence',
              query: {'contextId': id, 'page': page, 'size': size},
            ),
          );
          return (context: context, history: history);
        }),
      );
      if (!_current || !scope.isCurrent || generation != _read) return;
      final value = loaded.context;
      setState(() {
        _context = value;
        if (!preserveSelection) _lookup.text = id;
        _history = _ml(loaded.history['items']);
        _sidebar = [
          for (final evidence in _ml(value['sidebar']))
            {...evidence, ..._effective(evidence)},
        ];
        _sideActual = [];
        _rules = [
          for (final e in _ml(value['approved']))
            if (e['kind'] == 'GOODS' && _effective(e)['enabled'] != false)
              {..._effective(e), 'evidenceId': e['id']},
        ];
        _rule = preserveSelection && oldRule != null
            ? _rules.where((row) => row['evidenceId'] == oldRule).firstOrNull
            : _rules.firstOrNull;
        _sources = [];
        _error = null;
        _readDenied = false;
      });
    } catch (e) {
      if (isRetiredViewRead(e)) return;
      if (_current && generation == _read) setState(() => _readFailed(e));
    } finally {
      if (_current && generation == _read) setState(() => _busy = false);
    }
  }

  Future<void> _editor({
    String kind = 'CONTEXT',
    String mode = 'EDIT',
    String? evidenceId,
    String? resumeDraftId,
    Map<String, dynamic>? seed,
  }) async {
    if (!_current) return;
    final changed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UtenDialogFrame(
        child: SizedBox(
          width: 1180,
          height: MediaQuery.sizeOf(context).height * .92,
          child: _MaterialEditor(
            initialContextId: _context == null ? null : _id(_context),
            initialEvidenceId: evidenceId,
            kind: kind,
            mode: mode,
            resumeDraftId: resumeDraftId,
            seed: seed,
            dateFrom: _from.text,
            dateTo: _to.text,
          ),
        ),
      ),
    );
    if (!_current) return;
    if (changed == true) {
      _changed = true;
      await _load();
      if (_current && _context != null) await _openContext(_id(_context));
    }
  }

  Future<void> _compare({String? resumeDraftId}) async {
    if (!_current || (_context == null && resumeDraftId == null)) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UtenDialogFrame(
        child: SizedBox(
          width: 1380,
          height: MediaQuery.sizeOf(context).height * .92,
          child: _MaterialCompare(
            contextData: _context,
            dateFrom: _from.text,
            dateTo: _to.text,
            resumeDraftId: resumeDraftId,
          ),
        ),
      ),
    );
  }

  Future<void> _action(Map<String, dynamic> row, String action) => _editor(
    kind: row['kind'].toString(),
    mode: action,
    evidenceId: row['id'].toString(),
  );
  Future<void> _historyLoad() async {
    if (!_current || _context == null) return;
    final generation = ++_read;
    var partialRows = false;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiClientProvider),
          scope = await api.captureRequestScope(
            isCurrent: () => _current && generation == _read,
          );
      final value = await readViewActivity.runRead(
        () => _current && generation == _read,
        () => scope.run(
          () => _readMaterialPages(
            current: () => _current && generation == _read && scope.isCurrent,
            fetch: (batch, size) => api.get(
              '$_materialBase/evidence',
              query: {'contextId': _id(_context), 'page': batch, 'size': size},
            ),
            onRows: (items) {
              if (!_current || !scope.isCurrent || generation != _read) return;
              setState(() {
                _history = _ml(items);
                partialRows = true;
              });
            },
          ),
        ),
      );
      if (!_current || !scope.isCurrent || generation != _read) return;
      setState(() {
        _history = _ml(value['items']);
        partialRows = false;
        _error = null;
        _readDenied = false;
      });
    } catch (e) {
      if (isRetiredViewRead(e)) return;
      if (_current && generation == _read) {
        setState(() {
          if (partialRows) _history = [];
          _readFailed(e);
        });
      }
    } finally {
      if (_current && generation == _read) setState(() => _busy = false);
    }
  }

  /// 来源事实逐条展开为实物影响行（完整结果与逐批前缀同一投影）。
  List<Map<String, dynamic>> _sourceRows(List<Map<String, dynamic>> facts) {
    final rows = <Map<String, dynamic>>[];
    for (final fact in facts) {
      for (final effect in _ml(fact['effects'])) {
        rows.add({
          ...effect,
          'billNo': fact['billNo'],
          'originalSummary': [
            _mm(fact['sourceSnapshot'])['document_remark'],
            _mm(fact['sourceSnapshot'])['item_remark'],
          ].whereType<String>().where((value) => value.isNotEmpty).join('；'),
          'sourceUnitName': fact['unitName'],
          'goodsCode': fact['goodsCode'],
          'goodsName': fact['goodsName'],
          'source': fact['key'],
          'fact': fact,
          'sourceIdentityFingerprint': fact['identityFingerprint'],
          'flowRole': _rule!['flowRole'],
        });
      }
    }
    return rows;
  }

  Future<void> _sourceLoad() async {
    if (!_current || _context == null || _rule == null) return;
    final generation = ++_read;
    var partialRows = false;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiClientProvider),
          scope = await api.captureRequestScope(
            isCurrent: () => _current && generation == _read,
          );
      final result = await readViewActivity.runRead(
        () => _current && generation == _read,
        () => scope.run(
          () => _readMaterialPages(
            current: () => _current && generation == _read && scope.isCurrent,
            identity: (row) => row['key'],
            fetch: (batch, size) => api.get(
              '$_materialBase/sources',
              query: {
                'contextId': _id(_context),
                'kind': _rule!['sourceKind'],
                'sourceGoodsId': _rule!['goodsId'],
                'sourceColorId': _rule!['colorId'],
                'dateFrom': _from.text.trim(),
                'dateTo': _to.text.trim(),
                'page': batch,
                'size': size,
              },
            ),
            onRows: (items) {
              if (!_current || !scope.isCurrent || generation != _read) return;
              setState(() {
                _sources = _sourceRows(_ml(items));
                partialRows = true;
              });
            },
          ),
        ),
      );
      if (!_current || !scope.isCurrent || generation != _read) return;
      final rows = _sourceRows(_ml(result['items']));
      setState(() {
        _sources = rows;
        partialRows = false;
        _error = null;
        _readDenied = false;
      });
    } catch (e) {
      if (isRetiredViewRead(e)) return;
      if (_current && generation == _read) {
        setState(() {
          if (partialRows) _sources = [];
          _readFailed(e);
        });
      }
    } finally {
      if (_current && generation == _read) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _sourceSeed(Map<String, dynamic> row) => {
    'source': row['source'],
    'movementId': row['movementId'],
    'expectedIdentityFingerprint': row['sourceIdentityFingerprint'],
    'expectedEffectFingerprint': row['identityFingerprint'],
    '_sourceLabel':
        '${row['billNo']} ${row['goodsCode']} ${row['businessDate']}',
  };
  List<MasterColumnDef<Map<String, dynamic>>> _contextColumns() => [
    financeSourceColumn('auxiliaryName', '财务辅助项目', width: 190),
    financeSourceColumn('accountCode', '财务科目代码'),
    financeSourceColumn('productNameCaption', '产品名称（57#）', width: 240),
    financeSourceColumn('accountingCurrencyCode', '会计币别'),
    financeSourceColumn(
      'actualCurrencyId',
      '纸面金额单位',
      value: (r) => [
        r['actualCurrencyCode'],
        r['actualCurrencyName'],
      ].whereType<String>().where((s) => s.isNotEmpty).join(' / '),
    ),
    financeSourceColumn(
      'state',
      '分组资料',
      value: (r) => r['state'] == 'APPROVED' ? '已核对' : '草稿',
    ),
  ];
  Widget _directory() => financeSourceTable(
    tableKey: 'finance.material.contexts',
    columns: _contextColumns(),
    rows: _contexts,
    idOf: _id,
    busy: _busy,
    error: _error,
    retry: () => _load(),
    onOpen: (row) => _openContext(_id(row)),
  );
  Widget _recordTable() => _context == null
      ? const Center(child: Text('先选择财务辅助与材料分组'))
      : financeSourceTable(
          tableKey: 'finance.material.evidence.${_id(_context)}',
          rows: _history,
          error: _error,
          retry: _historyLoad,
          idOf: _id,
          busy: _busy,
          columns: [
            financeSourceColumn(
              'kind',
              '资料',
              value: (r) => _materialKinds[r['kind']] ?? r['kind']?.toString(),
            ),
            financeSourceColumn(
              'status',
              '状态',
              width: 190,
              value: (r) => _states[r['status']],
            ),
            financeSourceColumn('created_at', '建立时间', width: 190),
            MasterColumnDef(
              key: 'actions',
              label: '操作',
              width: 370,
              value: (_) => '',
              cellBuilder: (_, row) => UtenResponsiveActionWrap(
                children: [
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _busy
                        ? null
                        : () => _editor(
                            kind: row['kind'].toString(),
                            mode:
                                row['status'] == 'DRAFT' &&
                                    row['created_by'] ==
                                        ref
                                            .read(authenticatedScopeProvider)
                                            ?.userId &&
                                    _can(Perm.paymentStyleEdit)
                                ? 'EDIT'
                                : 'VIEW',
                            evidenceId: row['id'].toString(),
                          ),
                    child: const Text('查看／维护'),
                  ),
                  if (row['status'] == 'DRAFT' &&
                      row['created_by'] ==
                          ref.read(authenticatedScopeProvider)?.userId &&
                      _can(Perm.paymentStyleEdit))
                    UtenButton(
                      onPressed: _busy ? null : () => _action(row, 'submit'),
                      child: const Text('提交核对'),
                    ),
                  if (row['status'] == 'SUBMITTED' &&
                      row['submitted_by'] !=
                          ref.read(authenticatedScopeProvider)?.userId &&
                      _can(Perm.financePostExecute))
                    UtenButton(
                      onPressed: _busy ? null : () => _action(row, 'approve'),
                      child: const Text('审核'),
                    ),
                  if (row['current_approved'] == true &&
                      _can(Perm.paymentStyleEdit))
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _busy
                          ? null
                          : () => _editor(
                              kind: row['kind'].toString(),
                              evidenceId: row['id'].toString(),
                            ),
                      child: const Text('新建更正'),
                    ),
                  if (row['status'] == 'SUBMITTED' &&
                      row['submitted_by'] !=
                          ref.read(authenticatedScopeProvider)?.userId &&
                      _can(Perm.financePostExecute))
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _busy ? null : () => _action(row, 'reject'),
                      child: const Text('退回'),
                    ),
                  if ((row['status'] == 'DRAFT' &&
                              row['created_by'] ==
                                  ref
                                      .read(authenticatedScopeProvider)
                                      ?.userId ||
                          row['status'] == 'SUBMITTED' &&
                              row['submitted_by'] ==
                                  ref
                                      .read(authenticatedScopeProvider)
                                      ?.userId) &&
                      _can(Perm.paymentStyleEdit))
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _busy ? null : () => _action(row, 'withdraw'),
                      child: const Text('撤回'),
                    ),
                ],
              ),
            ),
          ],
        );
  Future<void> _loadSideActual() async {
    if (!_current || _context == null) return;
    final generation = ++_read;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiClientProvider),
          scope = await api.captureRequestScope(
            isCurrent: () => _current && generation == _read,
          );
      final result = await scope.run(
        () => api.get(
          '$_materialBase/sidebar-report',
          query: {
            'contextId': _id(_context),
            'dateFrom': _from.text.trim(),
            'dateTo': _to.text.trim(),
          },
        ),
      );
      if (!_current || !scope.isCurrent || generation != _read) return;
      setState(() {
        _sideActual = _ml(result['cells']);
        _showSideActual = true;
        _error = null;
        _readDenied = false;
      });
    } catch (error) {
      if (_current && generation == _read) {
        setState(() => _readFailed(error));
      }
    } finally {
      if (_current && generation == _read) setState(() => _busy = false);
    }
  }

  Widget _sidebarTable() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: UtenResponsiveActionWrap(
          children: [
            UtenButton(
              onPressed:
                  _busy || _context == null || !_can(Perm.paymentStyleEdit)
                  ? null
                  : () => _editor(kind: 'SIDEBAR'),
              child: const Text('新增原旁算资料'),
            ),
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _busy || _context == null ? null : _loadSideActual,
              child: const Text('展开本期真实旁算值'),
            ),
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _busy
                  ? null
                  : () => setState(() => _showSideActual = false),
              child: const Text('旁算资料清单'),
            ),
          ],
        ),
      ),
      Expanded(
        child: _showSideActual
            ? financeSourceTable(
                tableKey: 'finance.material.sidebar-actual',
                columns: [
                  financeSourceColumn('sourceCell', '原坐标'),
                  financeSourceColumn('value', '本期源值', width: 250),
                  financeSourceColumn('basis', '来源与口径', width: 540),
                  financeSourceColumn('pending', '待核'),
                ],
                rows: _sideActual,
                idOf: (row) => row['sourceCell'].toString(),
                busy: _busy,
              )
            : financeSourceTable(
                tableKey: 'finance.material.sidebar-reference',
                columns: [
                  financeSourceColumn('slot', '原位置'),
                  financeSourceColumn('dateFrom', '适用开始'),
                  financeSourceColumn('dateTo', '适用结束'),
                  financeSourceColumn('productNameCaption', '名称', width: 280),
                  financeSourceColumn(
                    'referencePrice',
                    '原型号／期间参考报价',
                    width: 260,
                  ),
                  financeSourceColumn(
                    'materialContextId',
                    '明确引用的真实组',
                    width: 260,
                  ),
                ],
                rows: _sidebar,
                idOf: _id,
                busy: _busy,
                onOpen: (row) => _editor(
                  kind: 'SIDEBAR',
                  evidenceId: _id(row),
                  mode: _can(Perm.paymentStyleEdit) ? 'EDIT' : 'VIEW',
                ),
              ),
      ),
    ],
  );
  Widget _sourceTable() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child: UtenResponsiveActionWrap(
          children: [
            SizedBox(
              width: 360,
              child: UtenDropdownField(
                label: '已核材料／产品对应',
                value: _rule?['evidenceId']?.toString(),
                items: [
                  for (final r in _rules)
                    UtenDropdownItem(
                      value: r['evidenceId'].toString(),
                      label:
                          '${_sourceKinds[r['sourceKind']]} / ${r['goodsId']} / ${_flowRoles[r['flowRole']]}',
                    ),
                ],
                onChanged: (id) {
                  setState(
                    () => _rule = _rules
                        .where((r) => r['evidenceId'] == id)
                        .firstOrNull,
                  );
                  _sourceLoad();
                },
              ),
            ),
            UtenButton(
              onPressed: _busy || _rule == null ? null : () => _sourceLoad(),
              child: const Text('读取实际来源'),
            ),
          ],
        ),
      ),
      Expanded(
        child: financeSourceTable(
          tableKey: 'finance.material.physical',
          rows: _sources,
          idOf: (r) => r['movementId'].toString(),
          busy: _busy,
          error: _error,
          columns: [
            financeSourceColumn('billNo', '原单号', width: 170),
            financeSourceColumn('businessDate', '原表日期'),
            financeSourceColumn('confirmationDate', '实际确认／反向日期', width: 180),
            financeSourceColumn('goodsCode', '真实货品编码'),
            financeSourceColumn('goodsName', '真实货品名称', width: 220),
            financeSourceColumn('baseQuantity', '原库存基本量', type: 'number'),
            financeSourceColumn('sourceUnitName', '原单单位'),
            financeSourceColumn('weightKg', '真实重量(KG)', type: 'number'),
            financeSourceColumn(
              'estimatedWeightKg',
              '原参考重量(KG)',
              type: 'number',
            ),
            MasterColumnDef(
              key: 'actions',
              label: '操作',
              width: 400,
              value: (_) => '',
              cellBuilder: (_, r) => UtenResponsiveActionWrap(
                children: [
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _busy || !_can(Perm.paymentStyleEdit)
                        ? null
                        : () => _editor(kind: 'WEIGHT', seed: _sourceSeed(r)),
                    child: const Text('实称／实点'),
                  ),
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _busy || !_can(Perm.paymentStyleEdit)
                        ? null
                        : () => _editor(
                            kind: 'SOURCE_RELATION',
                            seed: _sourceSeed(r),
                          ),
                    child: const Text('归入本组'),
                  ),
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed:
                        _busy ||
                            !_can(Perm.paymentStyleEdit) ||
                            r['flowRole'] != 'FINISHED_OUT'
                        ? null
                        : () => _editor(
                            kind: 'FEE',
                            seed: {'_feePart': _sourceSeed(r)},
                          ),
                    child: const Text('加工货款'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );
  Widget _boundedControls(Widget child) {
    final media = MediaQuery.sizeOf(context);
    return media.width >= 760
        ? child
        : ConstrainedBox(
            constraints: BoxConstraints(maxHeight: media.height * .40),
            child: SingleChildScrollView(child: child),
          );
  }

  @override
  Widget build(BuildContext context) {
    if (!_current || _readDenied) {
      return Material(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDialogSurface(
              child: UtenDialogHeader(
                title: const Text('访问范围已变化'),
                showCloseButton: true,
                onClose: () => Navigator.of(context).pop(_changed),
              ),
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Text(
                    _readDenied
                        ? (_error ?? '数据访问范围已变化，请重新进入。')
                        : '登录身份、权限或服务器已变化，请重新进入；原草稿仍属于原账号。',
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Material(
      child: Column(
        children: [
          UtenDialogSurface(
            child: UtenDialogHeader(
              title: const UtenDialogTitleWithHint(
                title: Text(
                  '${FinanceRequirementNames.otherReceivableStatement}资料',
                ),
                info:
                    '财务辅助与会计币别按原UUID对应，不以同名关联；资料仅作来源核对，不再记账。参考名称／有效期间报价独立保存，不建虚假主表组；未明确引用真实组的N/P/Q不填0。',
              ),
              showCloseButton: true,
              onClose: () => Navigator.of(context).pop(_changed),
            ),
          ),
          _boundedControls(
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Column(
                children: [
                  UtenFormGrid(
                    maxColumns: 3,
                    children: [
                      UtenSearchBar(
                        controller: _search,
                        hint: '辅助项目／材料名称',
                        onChanged: (_) => _load(),
                      ),
                      UtenInput(
                        label: '开始日期',
                        controller: _from,
                        onChanged: (_) {
                          _read++;
                          setState(() {
                            _busy = false;
                            _sources = [];
                          });
                        },
                      ),
                      UtenInput(
                        label: '结束日期',
                        controller: _to,
                        onChanged: (_) {
                          _read++;
                          setState(() {
                            _busy = false;
                            _sources = [];
                          });
                        },
                      ),
                      UtenInput(label: '恢复分组编号', controller: _lookup),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  UtenResponsiveActionWrap(
                    children: [
                      UtenButton(
                        onPressed: _busy || !_can(Perm.paymentStyleEdit)
                            ? null
                            : () => _editor(mode: 'NEW'),
                        child: const Text('新增分组资料'),
                      ),
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: _busy || _lookup.text.trim().isEmpty
                            ? null
                            : () => _openContext(_lookup.text.trim()),
                        child: const Text('恢复分组'),
                      ),
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: _busy || !_can(Perm.paymentStyleEdit)
                            ? null
                            : () async {
                                await showFinanceChartDialog(
                                  context,
                                  canEdit: true,
                                );
                                if (_current) await _load();
                              },
                        child: const Text('科目代码对应'),
                      ),
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: _busy
                            ? null
                            : () async {
                                await showFinanceAuxiliaryPicker(
                                  context,
                                  canEdit: _can(Perm.paymentStyleEdit),
                                  selection: false,
                                );
                                if (_current) await _load();
                              },
                        child: const Text('辅助项目'),
                      ),
                      UtenRefreshButton(
                        busy: _busy,
                        onRefresh: () async {
                          await _load();
                          if (_context != null) {
                            await _openContext(_id(_context));
                          }
                        },
                      ),
                      if (_context != null)
                        UtenButton(
                          type: UtenButtonType.secondary,
                          onPressed: _busy ? null : () => _compare(),
                          child: const Text('原表导入比对'),
                        ),
                      if (_context != null)
                        UtenButton(
                          type: UtenButtonType.secondary,
                          onPressed: _busy ? null : () => _editor(),
                          child: const Text('维护本组资料'),
                        ),
                    ],
                  ),
                  if (_context != null) Text('当前分组：${_context!['id']}'),
                ],
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: UtenSegmentRow<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('分组资料')),
                ButtonSegment(value: 1, label: Text('实际来源')),
                ButtonSegment(value: 2, label: Text('审核记录')),
                ButtonSegment(value: 3, label: Text('原隐藏旁算资料')),
              ],
              selected: {_tab},
              onSelectionChanged: (v) => setState(() => _tab = v.single),
            ),
          ),
          if (_context != null && _tab == 2)
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s8),
              child: UtenResponsiveActionWrap(
                children: [
                  for (final kind in _materialKinds.entries)
                    if (kind.key != 'CONTEXT')
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: _busy || !_can(Perm.paymentStyleEdit)
                            ? null
                            : () => _editor(kind: kind.key),
                        child: Text(kind.value),
                      ),
                ],
              ),
            ),
          Expanded(
            child: _tab == 0
                ? _directory()
                : _tab == 1
                ? _sourceTable()
                : _tab == 3
                ? _sidebarTable()
                : _recordTable(),
          ),
          if (_busy)
            const UtenBusyOverlay(
              title: '正在读取材料往来资料',
              showDoNotLeaveHint: false,
            ),
        ],
      ),
    );
  }
}
