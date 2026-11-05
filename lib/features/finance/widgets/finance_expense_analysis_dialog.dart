import '../../../components/layout/uten_editable_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/models/employee_reference.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/widgets/business_employee_picker.dart';
import '../../basic_data/widgets/uten_client_picker.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/formatters/money_display.dart';
import '../config/finance_requirement_names.dart';
import 'finance_entry_file_picker.dart';
import '../shared/finance_workbench_panel.dart';

const _base = '/finance/expense-analysis';
const _fees = [
  'SALARY',
  'SOCIAL',
  'FREIGHT',
  'OTHER',
  'TRAVEL',
  'ENTERTAIN',
  'AGENCY',
  'EXHIBITION',
  'LOADING',
  'MATERIAL',
  'REBATE',
  'COMPENSATION',
];
List<Map<String, dynamic>> _items(Object? data) => data is List
    ? [
        for (final row in data)
          if (row is Map) Map<String, dynamic>.from(row),
      ]
    : [];

/// All identifiers are retained through drafts; captions never establish a source UUID.
Future<bool> showFinanceExpenseAnalysisDialog(
  BuildContext context, {
  required String period,
  required String mode,
  String? lineKey,
  String? entryId,
  String? groupId,
  String? resumeDraftId,
}) async {
  final scope = <String, dynamic>{
    'period': period,
    'lineKey': ?lineKey,
    'entryId': ?entryId,
    'groupId': ?groupId,
  };
  final select =
      (mode == 'note' && lineKey == null) ||
      (mode == 'assignment' && entryId == null) ||
      (mode == 'group' && groupId == null);
  Widget workspace(BuildContext context) => UtenDialogFrame(
    child: SizedBox(
      width: 980,
      height: MediaQuery.sizeOf(context).height * .88,
      child: select
          ? _Manager(mode: mode, period: period)
          : FinanceExpenseAnalysisSurface(
              mode: mode,
              scope: scope,
              resumeDraftId: resumeDraftId,
            ),
    ),
  );
  final changed = select || mode == 'assignment'
      ? await showFinanceWorkbenchPanel<bool>(
          context: context,
          builder: workspace,
        )
      : await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: workspace,
        );
  return changed ?? false;
}

class _Manager extends ConsumerStatefulWidget {
  const _Manager({required this.mode, required this.period});
  final String mode, period;
  @override
  ConsumerState<_Manager> createState() => _ManagerState();
}

class _ManagerState extends ConsumerState<_Manager> {
  late final int _epoch;
  late final ApiClient _api;
  List<Map<String, dynamic>> _rows = [], _recent = [];
  Map<String, dynamic>? _preview, _pendingApply;
  bool _busy = false, _changed = false, _unknown = false;
  String? _error;
  int _page = 1;
  final Map<String, String> _filters = {};
  bool _more = false;
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  String get _title => widget.mode == 'note'
      ? '${FinanceRequirementNames.operatingProfit} · 备注/差异原因'
      : '${FinanceRequirementNames.salesExpense} · ${widget.mode == 'group' ? '分组资料' : '来源分配'}';
  @override
  void initState() {
    super.initState();
    _epoch = ref.read(exportContextEpochProvider);
    _api = ref.read(apiClientProvider);
    _load();
  }

  Future<void> _load() async {
    if (!_current || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = await _api.get(
        '$_base/${widget.mode == 'note'
            ? 'notes'
            : widget.mode == 'group'
            ? 'groups'
            : 'entries'}',
        query: {
          'period': widget.period,
          if (widget.mode == 'assignment') 'page': _page,
          if (widget.mode == 'assignment') 'size': 50,
        },
      );
      final recent = widget.mode == 'note'
          ? await _api.get(
              '$_base/note-imports',
              query: {'period': widget.period},
            )
          : <String, dynamic>{};
      if (!_current) return;
      setState(() {
        _rows = _items(value[widget.mode == 'assignment' ? 'rows' : 'items']);
        _recent = _items(recent['items']);
        _more =
            (_rows.length == 50) &&
            ((_page < ((value['totalPages'] as num?)?.toInt() ?? _page + 1)));
      });
    } catch (error) {
      if (_current) {
        setState(() => _error = humanErrorMessage(error) ?? '资料未读取完成');
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _open(Map<String, dynamic>? row) async {
    if (_busy || _unknown || !_current) return;
    final changed = await showFinanceExpenseAnalysisDialog(
      context,
      period: widget.period,
      mode: widget.mode,
      lineKey: row?['lineKey']?.toString(),
      entryId: row?['entryId']?.toString(),
      groupId: widget.mode == 'group'
          ? (row?['id']?.toString() ?? const Uuid().v4())
          : null,
    );
    if (!_current) return;
    _changed |= changed;
    await _load();
  }

  Future<void> _seed() async {
    if (_busy || _unknown || !_current) return;
    setState(() => _busy = true);
    try {
      await _api.post(
        '$_base/groups/seed-template',
        query: {'period': widget.period},
      );
      if (_current) _changed = true;
    } catch (error) {
      if (mounted && _current) {
        context.appApiError(error, fallback: '目录未恢复，可重试同一操作');
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
    await _load();
  }

  Future<void> _pick() async {
    if (_busy || _unknown || !_current) return;
    final file = await ref.read(financeEntryFilePickerProvider)();
    if (!mounted || !_current || file == null) return;
    if (!const {'xls', 'xlsx'}.contains(file.extension?.toLowerCase()) ||
        file.bytes == null ||
        file.bytes!.isEmpty ||
        file.bytes!.length > 15 * 1024 * 1024) {
      context.appWarning('请选择完整XLS或XLSX原表，最大15MB');
      return;
    }
    setState(() => _busy = true);
    try {
      final p = await _api.postBytes(
        '$_base/notes/import-preview-bytes',
        file.bytes!,
        query: {'period': widget.period, 'filename': file.name},
      );
      if (_current) setState(() => _preview = p);
    } catch (error) {
      if (mounted && _current) {
        context.appApiError(error, fallback: '预览未读取完成，可从最近批次恢复或重传同一文件');
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
    await _load();
  }

  Future<void> _restore(String id) async {
    if (_busy || _unknown || !_current) return;
    setState(() => _busy = true);
    try {
      final p = await _api.get('$_base/note-imports/$id');
      if (_current) setState(() => _preview = p);
    } catch (error) {
      if (mounted && _current) context.appApiError(error);
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    if (_busy || !_current) return;
    final body =
        _pendingApply ??
        (_preview == null
            ? null
            : <String, dynamic>{'importId': _preview!['importId']});
    if (body == null) return;
    setState(() => _busy = true);
    _pendingApply = Map.from(body);
    try {
      await _api.post('$_base/notes/import-apply', body: _pendingApply);
      if (!mounted || !_current) return;
      setState(() {
        _unknown = false;
        _pendingApply = null;
        _changed = true;
        _preview = null;
      });
      context.appSuccess('备注和差异原因已导入');
    } catch (error) {
      if (mounted && _current) {
        final rejected =
            error is ApiException &&
            error.hasResponseCode &&
            (error.httpStatus ?? 0) >= 400 &&
            (error.httpStatus ?? 0) < 500 &&
            error.httpStatus != 408;
        setState(() {
          _unknown = !rejected;
          if (rejected) _pendingApply = null;
        });
        context.appApiError(error, fallback: '结果尚未确认，请保留本批次并重试原请求');
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
    await _load();
  }

  List<MasterColumnDef<Map<String, dynamic>>> get _columns {
    MasterColumnDef<Map<String, dynamic>> column(
      String key,
      String label,
      double width, {
      bool amount = false,
    }) => MasterColumnDef(
      key: key,
      label: label,
      width: width,
      value: (row) => amount
          ? (row['${key}Exact'] ?? row[key])?.toString() ?? ''
          : row[key]?.toString() ?? '',
      filterFromRows: widget.mode != 'assignment',
      columnSearchEnabled: widget.mode != 'assignment',
      cellBuilder: amount
          ? (_, row) => Text(
              financeMoneyText((row['${key}Exact'] ?? row[key])?.toString()),
            )
          : null,
    );
    return switch (widget.mode) {
      'note' => [
        column('category', '项目分类', 130),
        column('sub', '分项', 170),
        column('item', '具体项目', 230),
        column('remark', '备注', 240),
        column('varianceReason', '差异原因', 240),
      ],
      'group' => [
        column('label', '销售费用项目', 220),
        column('sourceReference', '来源依据', 320),
        MasterColumnDef(
          key: 'reviewed',
          label: '归属状态',
          width: 100,
          value: (row) => row['reviewed'] == true ? '已核对' : '待核对',
        ),
      ],
      _ => [
        column('date', '日期', 130),
        column('billNo', '来源单号', 160),
        column('styleCode', '科目编码', 110),
        column('styleName', '科目名称', 220),
        column('amount', '本币金额', 150, amount: true),
        column('status', '归属状态', 100),
      ],
    };
  }

  @override
  Widget build(BuildContext context) {
    final epoch = ref.watch(exportContextEpochProvider),
        api = ref.watch(apiClientProvider);
    if (epoch != _epoch || !identical(api, _api)) {
      return Material(
        child: Column(
          children: [
            UtenDialogHeader(
              title: const Text('访问范围已变化'),
              showCloseButton: true,
              onClose: () => Navigator.of(context).pop(false),
            ),
            const Expanded(
              child: Center(child: Text('请关闭后重新读取。原导入批次会保留在原账号的最近批次中。')),
            ),
          ],
        ),
      );
    }
    return PopScope(
      canPop: !_busy && !_unknown,
      child: Material(
        child: Column(
          children: [
            UtenDialogHeader(
              title: Text(_title),
              showCloseButton: true,
              onClose: () {
                if (!_busy && !_unknown) Navigator.of(context).pop(_changed);
              },
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(widget.period),
                  UtenButton(
                    onPressed: _busy || _unknown ? null : _load,
                    child: const Text('刷新'),
                  ),
                  if (widget.mode == 'group') ...[
                    UtenButton(
                      onPressed: _busy || _unknown ? null : () => _open(null),
                      child: const Text('新增分组'),
                    ),
                    UtenButton(
                      onPressed: _busy || _unknown ? null : _seed,
                      child: const Text('载入原表分组目录'),
                    ),
                  ],
                  if (widget.mode == 'note')
                    UtenButton(
                      onPressed: _busy || _unknown ? null : _pick,
                      child: const Text('导入备注/差异原因'),
                    ),
                  if (widget.mode == 'assignment') ...[
                    UtenButton(
                      onPressed: _busy || _page <= 1
                          ? null
                          : () {
                              _page--;
                              _load();
                            },
                      child: const Text('上一页'),
                    ),
                    Text('第$_page页'),
                    UtenButton(
                      onPressed: _busy || !_more
                          ? null
                          : () {
                              _page++;
                              _load();
                            },
                      child: const Text('下一页'),
                    ),
                  ],
                ],
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
            if (_unknown)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('原导入请求结果尚未确认，请点击重试原请求；批次和原文件已保留。'),
              ),
            if (widget.mode == 'note' && _recent.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: UtenDropdownField(
                  label: '最近导入批次',
                  value: null,
                  items: [
                    for (final row in _recent)
                      UtenDropdownItem(
                        value: row['importId'].toString(),
                        label:
                            '${row['sourceName']} ${row['appliedAt'] == null ? '未应用' : '已应用'}',
                      ),
                  ],
                  enabled: !_busy && !_unknown,
                  onChanged: (v) {
                    if (v != null) _restore(v);
                  },
                ),
              ),
            if (_preview != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_preview!['sourceName']}：${(_preview!['rows'] as List?)?.length ?? 0}项备注；空白保留已保存内容',
                    ),
                    for (final issue in _items(_preview!['issues']).take(8))
                      Text(
                        '第${issue['sourceRow']}行 ${issue['field']}：${issue['message']}',
                      ),
                    UtenButton(
                      onPressed:
                          _busy ||
                              (_preview!['issues'] as List?)?.isNotEmpty ==
                                  true ||
                              _preview!['applied'] == true
                          ? null
                          : _apply,
                      child: Text(_unknown ? '重试原请求' : '应用预览'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: MasterDataTableView<Map<String, dynamic>>(
                tableKey: 'finance.expense-analysis.${widget.mode}',
                columns: _columns,
                items: _rows,
                facets: const {},
                nullCounts: const {},
                filters: _filters,
                onFilterChanged: (key, value) {
                  if (widget.mode != 'assignment') {
                    setState(() {
                      if (value == null) {
                        _filters.remove(key);
                      } else {
                        _filters[key] = value;
                      }
                    });
                  }
                },
                isLoading: _busy,
                error: _error,
                onRetry: _load,
                emptyMessage: '本期间暂无资料，请核对原始来源和取数配置',
                showPaginationControls: false,
                showFullscreenToggle: false,
                onRowTap: _busy || _unknown ? null : _open,
                headerFilterScopeDescription: widget.mode == 'assignment'
                    ? '本页来源分录；使用上方翻页读取其它来源'
                    : '定位原表项目，保留原顺序',
              ),
            ),
            if (_busy)
              const UtenBusyOverlay(
                title: '正在核对费用资料',
                showDoNotLeaveHint: false,
              ),
          ],
        ),
      ),
    );
  }
}

class FinanceExpenseAnalysisSurface extends ConsumerStatefulWidget {
  const FinanceExpenseAnalysisSurface({
    super.key,
    required this.mode,
    required this.scope,
    this.resumeDraftId,
  });
  final String mode;
  final Map<String, dynamic> scope;
  final String? resumeDraftId;
  @override
  ConsumerState<FinanceExpenseAnalysisSurface> createState() => _EditorState();
}

class _EditorState extends ConsumerState<FinanceExpenseAnalysisSurface>
    with FormDraftMixin<FinanceExpenseAnalysisSurface> {
  late final String _originalMode = widget.mode;
  late final Map<String, dynamic> _originalScope = Map.unmodifiable(
    widget.scope,
  );
  final Map<String, TextEditingController> _text = {};
  Map<String, dynamic> _source = {}, _flags = {};
  List<Map<String, dynamic>> _groups = [];
  final _allocationGrid = UtenEditableGridController<_AllocationRow>();
  Map<String, dynamic>? _sent;
  String? _error, _employeeId, _channel;
  bool _loading = true, _saving = false;
  int _version = -1;
  String get _mode => _originalMode;
  String get _period => _originalScope['period'].toString();
  bool get _sameSource =>
      widget.mode == _originalMode &&
      widget.scope.length == _originalScope.length &&
      _originalScope.entries.every((e) => widget.scope[e.key] == e.value);
  TextEditingController _c(String key) =>
      _text.putIfAbsent(key, () => TextEditingController());
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.financeExpenseAnalysisInput.spec(
        title: '费用原表资料 · $_period',
        routeParameters: {
          'expenseMode': _mode,
          for (final e in _originalScope.entries)
            'expense.${e.key}': e.value.toString(),
        },
      );
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => _saving;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftCanReplaySubmission => _sent != null;
  @override
  Iterable<Listenable> get formDraftListenables => [
    ..._text.values,
    ..._allocationGrid.rows.map((r) => r.amount),
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'mode': _mode,
    'scope': _originalScope,
    'text': {for (final e in _text.entries) e.key: e.value.text},
    'version': _version,
    'source': _source,
    'flags': _flags,
    'employeeId': _employeeId,
    'channel': _channel,
    'allocations': [for (final row in _allocationGrid.rows) row.capture()],
    'sent': _sent,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['mode'] != _mode ||
        data['scope'] is! Map ||
        (data['scope'] as Map).length != _originalScope.length ||
        _originalScope.entries.any(
          (e) => (data['scope'] as Map)[e.key] != e.value,
        )) {
      throw StateError('费用草稿的原项目、来源或期间不一致');
    }
    if (data['text'] is Map) {
      for (final e in (data['text'] as Map).entries) {
        _c(e.key.toString()).text = e.value?.toString() ?? '';
      }
    }
    _version = (data['version'] as num?)?.toInt() ?? -1;
    _source = data['source'] is Map
        ? Map<String, dynamic>.from(data['source'] as Map)
        : {};
    _flags = data['flags'] is Map
        ? Map<String, dynamic>.from(data['flags'] as Map)
        : {};
    _employeeId = data['employeeId'] as String?;
    _channel = data['channel'] as String?;
    _replaceAllocations(
      _items(data['allocations']),
      legacyText: data['text'] is Map ? data['text'] as Map : const {},
    );
    _sent = data['sent'] is Map
        ? Map<String, dynamic>.from(data['sent'] as Map)
        : null;
  }

  @override
  void initState() {
    super.initState();
    for (final key in [
      'remark',
      'varianceReason',
      'sourceReference',
      'label',
      'salesAmountLocal',
      'directPositive',
      'indirectPositive',
      'directNegative',
      'indirectNegative',
      'unlockReason',
    ]) {
      _c(key);
    }
    _allocationGrid.addListener(_allocationRowsChanged);
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _allocationGrid.removeListener(_allocationRowsChanged);
    _allocationGrid.dispose();
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void didUpdateWidget(FinanceExpenseAnalysisSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameSource) {
      _error = '期间或来源已变化，请关闭并重新打开；原输入仍保留在原项目草稿中';
      _loading = false;
    }
  }

  Future<void> _load() async {
    try {
      final scope = await captureFormDraftRequestScope();
      final api = ref.read(apiClientProvider);
      Map<String, dynamic> value = {};
      if (_mode == 'note') {
        final r = await scope.run(
          () => api.get('$_base/notes', query: {'period': _period}),
        );
        value = _items(
          r['items'],
        ).firstWhere((r) => r['lineKey'] == _originalScope['lineKey']);
      } else if (_mode == 'group') {
        final r = await scope.run(
          () => api.get('$_base/groups', query: {'period': _period}),
        );
        value =
            _items(
              r['items'],
            ).where((r) => r['id'] == _originalScope['groupId']).firstOrNull ??
            {};
      } else {
        value = await scope.run(
          () => api.get(
            '$_base/${_mode == 'assignment' ? 'entries/${_originalScope['entryId']}' : _mode}',
            query: _mode == 'assignment' ? null : {'period': _period},
          ),
        );
      }
      if (_mode == 'assignment') {
        final groups = await scope.run(
          () => api.get('$_base/groups', query: {'period': _period}),
        );
        _groups = _items(groups['items']);
        value['feeHeaders'] = groups['feeHeaders'];
      }
      if (!mounted || !formDraftIdentityIsCurrent || !scope.isCurrent) return;
      _source = value;
      _version = (value['version'] as num?)?.toInt() ?? -1;
      for (final e in _text.entries) {
        e.value.text = value[e.key]?.toString() ?? '';
      }
      for (final k in ['reviewed', 'confirmed', 'locked', 'salesConfirmed']) {
        _flags[k] = value[k] == true;
      }
      _employeeId = value['employeeId']?.toString();
      _channel = value['channel']?.toString();
      _replaceAllocations(_items(value['allocations']));
      setState(() => _loading = false);
      await initializeFormDraft();
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        setState(() {
          _loading = false;
          _error = humanErrorMessage(error) ?? '原表资料未读取完成';
        });
      }
    }
  }

  Map<String, dynamic> _payload() => switch (_mode) {
    'note' => {
      'period': _period,
      'lineKey': _originalScope['lineKey'],
      'expectedVersion': _version,
      'remark': _c('remark').text,
      'varianceReason': _c('varianceReason').text,
    },
    'labor' => {
      'period': _period,
      'expectedVersion': _version,
      'sourceFingerprint': _source['sourceFingerprint'],
      for (final key in [
        'directPositive',
        'indirectPositive',
        'directNegative',
        'indirectNegative',
      ])
        key: _c(key).text.trim(),
      'reviewed': _flags['reviewed'] == true,
      'sourceReference': _c('sourceReference').text,
    },
    'policy' => {
      'period': _period,
      'expectedVersion': _version,
      'confirmed': _flags['confirmed'] == true,
      'locked': _flags['locked'] == true,
      'sourceReference': _c('sourceReference').text,
      'unlockReason': _c('unlockReason').text,
    },
    'group' => {
      'id': _originalScope['groupId'],
      'period': _period,
      'expectedVersion': _version,
      'label': _c('label').text,
      'employeeId': _employeeId,
      'channel': _channel,
      'salesAmountLocal': _c('salesAmountLocal').text.trim().isEmpty
          ? null
          : _c('salesAmountLocal').text.trim(),
      'salesConfirmed': _flags['salesConfirmed'] == true,
      'reviewed': _flags['reviewed'] == true,
      'sourceReference': _c('sourceReference').text,
      'sortOrder': _source['sortOrder'] ?? 0,
    },
    'assignment' => {
      'entryId': _originalScope['entryId'],
      'expectedVersion': _version,
      'sourceFingerprint': _source['sourceFingerprint'],
      'sourceReference': _c('sourceReference').text,
      'allocations': [
        for (final row in _allocationGrid.rows)
          {
            'groupId': row.data['groupId'],
            'feeKey': row.data['feeKey'],
            'clientId': row.data['clientId'],
            'amountLocal': row.amount.text.trim(),
          },
      ],
    },
    _ => throw StateError('费用资料类型无效'),
  };
  Future<void> _save() async {
    if (_saving || !formDraftIdentityIsCurrent || !_sameSource) return;
    final scope = await captureFormDraftRequestScope();
    if (!mounted || !scope.isCurrent) return;
    setState(() => _saving = true);
    try {
      _sent ??= _payload();
      await runFormDraftSubmission(
        () => UtenBusyOverlay.run(
          context,
          title: '正在保存费用原表资料',
          action: () => scope.run(
            () => ref
                .read(apiClientProvider)
                .post(
                  '$_base/${switch (_mode) {
                    'note' => 'notes',
                    'group' => 'groups',
                    'assignment' => 'assignments',
                    _ => _mode,
                  }}',
                  body: _sent,
                ),
          ),
        ),
      );
      if (!mounted || !formDraftIdentityIsCurrent || !scope.isCurrent) return;
      await completeFormDraft();
      if (mounted) {
        context.appSuccess('费用原表资料已保存');
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (!formDraftHasUnknownSubmission) _sent = null;
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '保存结果尚未确认，原输入已保留');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _close() async {
    if (!_saving && await confirmFormDraftExit() && mounted) {
      Navigator.of(context).pop(false);
    }
  }

  Widget _input(String key, String label, {int lines = 1}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: UtenInput(
      controller: _c(key),
      label: label,
      maxLines: lines,
      enabled: !_saving && _sent == null,
    ),
  );
  Widget _check(String key, String label) => CheckboxListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    value: _flags[key] == true,
    enabled: !_saving && _sent == null,
    onChanged: (v) {
      setState(() => _flags[key] = v == true);
      markFormDraftChanged();
    },
  );
  void _allocationRowsChanged() {
    if (mounted && !_loading) {
      setState(() {});
      markFormDraftChanged();
    }
  }

  void _replaceAllocations(
    List<Map<String, dynamic>> values, {
    Map<dynamic, dynamic> legacyText = const {},
  }) {
    _allocationGrid.replaceAll([
      for (int i = 0; i < values.length; i++)
        _AllocationRow(
          values[i],
          legacyText['amount$i']?.toString() ??
              values[i]['amountLocal']?.toString() ??
              '',
          markFormDraftChanged,
        ),
    ]);
  }

  Future<void> _client(_AllocationRow row) async {
    final item = await showUtenClientPicker(
      context,
      ref,
      selectableOnly: false,
      excludeLegacyFinanceStub: false,
    );
    if (!mounted ||
        !formDraftIdentityIsCurrent ||
        item == null ||
        !_allocationGrid.rows.contains(row)) {
      return;
    }
    setState(() {
      row.data['clientId'] = item.id;
      row.data['clientLabel'] = clientPickerLabel(item);
    });
    markFormDraftChanged();
  }

  Widget _allocationEditor() {
    final enabled = !_saving && _sent == null,
        headers = (_source['feeHeaders'] as List?) ?? const [];
    String groupName(_AllocationRow row) =>
        _groups
            .where((g) => g['id'] == row.data['groupId'])
            .firstOrNull?['label']
            ?.toString() ??
        '';
    String feeName(_AllocationRow row) {
      final i = _fees.indexOf(row.data['feeKey']?.toString() ?? '');
      return i >= 0 && i + 2 < headers.length ? headers[i + 2].toString() : '';
    }

    return UtenEditableGrid<_AllocationRow>(
      tableKey: 'finance.expense-analysis.assignments',
      controller: _allocationGrid,
      showAddRow: enabled,
      createBlankRow: () => _AllocationRow({}, '', markFormDraftChanged),
      showRowDelete: enabled,
      canDeleteRow: (_) => enabled,
      showRemoveRowsAction: enabled,
      selectable: enabled,
      selectionEnabled: enabled,
      columns: [
        EditableGridColumn(
          key: 'groupId',
          label: headers.length > 1 ? headers[1].toString() : '销售费用项目',
          width: 220,
          textOf: groupName,
          cellBuilder: (_, row) => UtenDropdownField(
            value: row.data['groupId']?.toString(),
            items: [
              for (final g in _groups)
                UtenDropdownItem(
                  value: g['id'].toString(),
                  label: g['label'].toString(),
                ),
            ],
            enabled: enabled,
            onChanged: (v) {
              setState(() => row.data['groupId'] = v);
              markFormDraftChanged();
            },
          ),
        ),
        EditableGridColumn(
          key: 'feeKey',
          label: '费用项目',
          width: 220,
          textOf: feeName,
          cellBuilder: (_, row) => UtenDropdownField(
            value: row.data['feeKey']?.toString(),
            items: [
              for (int n = 0; n < _fees.length && n + 2 < headers.length; n++)
                UtenDropdownItem(
                  value: _fees[n],
                  label: headers[n + 2].toString(),
                ),
            ],
            enabled: enabled,
            onChanged: (v) {
              setState(() => row.data['feeKey'] = v);
              markFormDraftChanged();
            },
          ),
        ),
        EditableGridColumn(
          key: 'amountLocal',
          label: '本币金额',
          width: 180,
          numeric: true,
          textOf: (row) => row.amount.text,
          exactValueOf: (row) => row.amount.text,
          exactListenableOf: (row) => row.amount,
          listenableOf: (row) => row.amount,
          cellBuilder: (_, row) =>
              UtenInput(controller: row.amount, enabled: enabled),
        ),
        EditableGridColumn(
          key: 'clientId',
          label: '客户',
          width: 270,
          textOf: (row) => row.data['clientLabel']?.toString() ?? '',
          cellBuilder: (_, row) => Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: enabled ? () => _client(row) : null,
                  child: Text(
                    row.data['clientLabel']?.toString() ??
                        (row.data['clientId'] == null ? '选择客户' : '客户名称待核对'),
                  ),
                ),
              ),
              IconButton(
                tooltip: '清除客户',
                onPressed: enabled
                    ? () {
                        setState(() {
                          row.data.remove('clientId');
                          row.data.remove('clientLabel');
                        });
                        markFormDraftChanged();
                      }
                    : null,
                icon: const Icon(Icons.clear),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => withFormDraft(
    Material(
      child: Column(
        children: [
          UtenDialogHeader(
            title: UtenDialogTitleWithHint(
              title: Text(
                '$_period · ${switch (_mode) {
                  'note' => '备注/差异原因',
                  'labor' => '直接人工/间接人工',
                  'group' => '销售费用分组',
                  'assignment' => '销售费用来源分配',
                  _ => '期间取数口径',
                }}',
              ),
              info: switch (_mode) {
                'policy' =>
                  '请核对期间实际消耗、费用归属，以及部门费用与费用性质、资本化成本是否重复。确认只记录核对结论，不替代来源覆盖和金额守恒。',
                'labor' => '没有明确410106原始分录时，请先对应职工薪酬费来源。没有工资事实不补0。',
                _ => null,
              },
            ),
            showCloseButton: true,
            onClose: _close,
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(child: Text(_error!))
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_mode == 'note') ...[
                          Text(
                            '${_source['category']} / ${_source['sub']} / ${_source['item']}',
                          ),
                          const SizedBox(height: 12),
                          _input('remark', '备注', lines: 4),
                          _input('varianceReason', '差异原因', lines: 4),
                        ],
                        if (_mode == 'labor') ...[
                          Text(
                            '职工薪酬费：正向 ${_source['positiveAmount'] ?? '待核'}；红字 ${_source['negativeAmount'] ?? '待核'}；${_source['sourceCount'] ?? 0}笔来源',
                          ),
                          const SizedBox(height: 12),
                          for (final pair in [
                            ('directPositive', '直接人工（正向）'),
                            ('indirectPositive', '间接人工（正向）'),
                            ('directNegative', '直接人工（红字）'),
                            ('indirectNegative', '间接人工（红字）'),
                          ])
                            _input(pair.$1, pair.$2),
                          _check('reviewed', '已核对正向与红字各自合计及直接/间接归属'),
                          ExpansionTile(
                            title: const Text('原始来源'),
                            children: [
                              for (final source in _items(_source['sources']))
                                ListTile(
                                  title: Text(
                                    '${source['date']} ${source['billNo'] ?? ''} ${source['amountLocal']}\n${source['entryId']}',
                                  ),
                                ),
                            ],
                          ),
                        ],
                        if (_mode == 'group') ...[
                          _input('label', '项目（按财务原表命名）'),
                          BusinessEmployeePicker(
                            purpose: EmployeeReferencePurpose
                                .financeExpenseAttribution,
                            selectedId: _employeeId,
                            label: '对应人员',
                            enabled: !_saving && _sent == null,
                            onChanged: (v) {
                              setState(() => _employeeId = v?.id);
                              markFormDraftChanged();
                            },
                          ),
                          const SizedBox(height: 12),
                          UtenDropdownField(
                            label: '渠道',
                            value: _channel,
                            items: const [
                              UtenDropdownItem(value: 'OEM', label: 'OEM'),
                              UtenDropdownItem(value: 'FOREIGN', label: '外贸'),
                              UtenDropdownItem(value: 'DOMESTIC', label: '内销'),
                              UtenDropdownItem(
                                value: 'MANAGEMENT',
                                label: '管理',
                              ),
                            ],
                            enabled: !_saving && _sent == null,
                            onChanged: (v) {
                              setState(() => _channel = v);
                              markFormDraftChanged();
                            },
                          ),
                          const SizedBox(height: 12),
                          _input('salesAmountLocal', '销售额'),
                          _check('salesConfirmed', '已核对此组销售额（确为零请明确填0）'),
                          _check('reviewed', '已核对本期实际分组和人员/渠道对应'),
                        ],
                        if (_mode == 'assignment') ...[
                          Text(
                            '${_source['date']} ${_source['billNo'] ?? ''} ${_source['styleName']}；本币金额 ${_source['amountLocal']}',
                          ),
                          const SizedBox(height: 12),
                          _allocationEditor(),
                        ],
                        if (_mode == 'policy') ...[
                          _check('confirmed', '已核对期间口径并排除重复扣减'),
                          _check('locked', '锁定本期间归属资料'),
                          _input('unlockReason', '解除锁定原因'),
                        ],
                        if (_mode != 'note')
                          _input('sourceReference', '来源/核对依据', lines: 3),
                      ],
                    ),
                  ),
          ),
          UtenDialogActions(
            children: [
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: _saving ? null : _close,
                child: const Text('关闭'),
              ),
              UtenButton(
                onPressed: _saving || _loading || _error != null ? null : _save,
                child: Text(
                  _saving
                      ? '保存中…'
                      : _sent != null
                      ? '重试原请求'
                      : '保存',
                ),
              ),
            ],
          ),
          if (_loading)
            const UtenBusyOverlay(title: '正在读取费用资料', showDoNotLeaveHint: false),
        ],
      ),
    ),
  );
}

class _AllocationRow extends EditableGridRow {
  _AllocationRow(Map<String, dynamic> value, String raw, this.changed)
    : data = Map<String, dynamic>.from(value),
      amount = TextEditingController(text: raw) {
    data.putIfAbsent('__uiId', () => const Uuid().v4());
    amount.addListener(changed);
  }
  final Map<String, dynamic> data;
  final TextEditingController amount;
  final VoidCallback changed;
  Map<String, dynamic> capture() => {...data, 'amountLocal': amount.text};
  @override
  void dispose() {
    amount.removeListener(changed);
    amount.dispose();
    super.dispose();
  }
}
