import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import 'finance_entry_file_picker.dart';
import 'gl_report_line_bindings_dialog.dart';
import 'finance_native_posting_accounts_dialog.dart';
import '../config/finance_requirement_names.dart';

List<Map<String, dynamic>> _maps(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map<String, dynamic>) row,
];

Future<bool> showFinanceChartDialog(
  BuildContext context, {
  required bool canEdit,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FinanceChartDialog(canEdit: canEdit),
    ) ??
    false;

/// Accounting codes retain their source order; all allocations use verified system UUIDs.
class FinanceChartDialog extends ConsumerStatefulWidget {
  const FinanceChartDialog({required this.canEdit, super.key});
  final bool canEdit;
  @override
  ConsumerState<FinanceChartDialog> createState() => _FinanceChartDialogState();
}

class _FinanceChartDialogState extends ConsumerState<FinanceChartDialog> {
  late final int _ownerEpoch;
  late final ApiClient _api;
  List<Map<String, dynamic>> _accounts = [], _recent = [], _currencies = [];
  Map<String, dynamic>? _preview;
  String? _error;
  String _keyword = '';
  bool _busy = false, _changed = false, _unknown = false;
  bool _newAccountOpen = false;
  Map<String, dynamic>? _pendingMapping;
  Map<String, dynamic>? _pendingCreation;
  Map<String, dynamic>? _pendingNewAccount;
  String? _pendingCode;
  bool get _current =>
      mounted &&
      _ownerEpoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));

  @override
  void initState() {
    super.initState();
    _ownerEpoch = ref.read(exportContextEpochProvider);
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
      final results = await Future.wait([
        _api.get('/finance/chart'),
        _api.get('/finance/chart/options'),
        if (widget.canEdit) _api.get('/finance/chart/imports'),
      ]);
      if (!_current) return;
      setState(() {
        _accounts = _maps(results[0]['items']);
        _currencies = _maps(results[1]['currencies']);
        _recent = widget.canEdit ? _maps(results[2]['items']) : [];
      });
    } catch (error) {
      if (_current) setState(() => _error = _message(error));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  String _message(Object error) =>
      error is ApiException ? error.message : '操作未完成，请核对网络后重试';
  bool _rejected(Object error) =>
      error is ApiException &&
      error.hasResponseCode &&
      (error.httpStatus ?? 0) >= 400 &&
      (error.httpStatus ?? 0) < 500 &&
      error.httpStatus != 408;

  Future<void> _pick() async {
    if (!_current || _busy || _unknown) return;
    final file = await ref.read(financeEntryFilePickerProvider)();
    if (!_current || file == null) return;
    final ext = file.extension?.toLowerCase();
    if (ext != 'xls' && ext != 'xlsx') {
      setState(() => _error = '科目目录请选择XLS或XLSX文件');
      return;
    }
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty || bytes.length > 15 * 1024 * 1024) {
      setState(() => _error = '文件为空、未完整读取或超过15MB');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview = await _api.postMultipartFile(
        '/finance/chart/import-preview',
        bytes,
        file.name,
        ext == 'xls'
            ? 'application/vnd.ms-excel'
            : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
      if (_current) setState(() => _preview = preview);
    } catch (error) {
      if (_current) {
        setState(() => _error = '${_message(error)}。上传结果不确定时，请刷新并从最近批次恢复预览');
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _restore(Map<String, dynamic> batch) async {
    if (!_current || _busy || _unknown) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview = await _api.get(
        '/finance/chart/imports/${batch['importId']}',
      );
      if (_current) setState(() => _preview = preview);
    } catch (error) {
      if (_current) setState(() => _error = _message(error));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    if (!_current ||
        _busy ||
        _preview == null ||
        _pendingMapping != null ||
        _pendingCreation != null) {
      return;
    }
    final id = _preview!['importId'];
    if (_maps(_preview!['issues']).isNotEmpty || _preview!['applied'] == true) {
      return;
    }
    final wasUnknown = _unknown;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.post('/finance/chart/import-apply', body: {'importId': id});
      if (!_current) return;
      setState(() {
        _preview = null;
        _changed = true;
        _unknown = false;
      });
    } catch (error) {
      if (_current) {
        setState(() {
          _unknown = wasUnknown || !_rejected(error);
          _error = _unknown
              ? '${_message(error)}。保留原批次，点击“核对并重试原批次”，不会重新导入一份'
              : _message(error);
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
    if (_current && !_unknown) await _load();
  }

  Future<void> _edit(Map<String, dynamic> account) async {
    if (!_current || _busy || _unknown) return;
    var send = false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rawLines = await _api.getList(GlReportLineBindingEndpoints.list);
      final lines = rawLines
          .map(GlReportLineBinding.fromJson)
          .where((line) => line.sheet == 'BALANCE' || line.sheet == 'PROFIT')
          .toList();
      final trees = await Future.wait([
        for (final category in const [
          'ACCOUNT',
          'LIABILITY',
          'EQUITY',
          'INCOME',
          'EXPENSE',
        ])
          _api.getList(
            GlReportLineBindingEndpoints.expenseStyles,
            query: {'category': category},
          ),
      ]);
      if (!_current) return;
      final candidates = <GlReportLineCandidate>[];
      const categories = [
        'ACCOUNT',
        'LIABILITY',
        'EQUITY',
        'INCOME',
        'EXPENSE',
      ];
      for (var i = 0; i < trees.length; i++) {
        candidates.addAll(
          flattenExpenseLeaves(trees[i], category: categories[i]),
        );
      }
      if (!mounted) return;
      final initial = <String, dynamic>{...account};
      if (_pendingCode == account['code'] && _pendingMapping != null) {
        initial['classification'] = _pendingMapping!['classification'];
        initial['currencyId'] = _pendingMapping!['currencyId'];
        initial['targets'] = [
          for (final id in _pendingMapping!['styleIds'] as List) {'id': id},
        ];
        initial['lineKeys'] = [
          _pendingMapping!['balanceLineKey'],
          _pendingMapping!['profitLineKey'],
        ].whereType<String>().toList();
      }
      if (_pendingCode == account['code'] && _pendingCreation != null) {
        initial['classification'] = _pendingCreation!['classification'];
        initial['creationCategory'] = _pendingCreation!['category'];
      }
      final mapping = await UtenBusyOverlay.yieldWhile(
        () => showDialog<Map<String, dynamic>>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _ChartMappingDialog(
            account: initial,
            candidates: candidates,
            lines: lines,
            ownerEpoch: _ownerEpoch,
            canCreate: ref
                .read(currentPermissionsProvider)
                .contains(Perm.paymentStyleCreate),
            currencies: _currencies,
          ),
        ),
      );
      if (!_current || mapping == null) return;
      _pendingCode = account['code'].toString();
      _pendingCreation = mapping.containsKey('category') ? mapping : null;
      _pendingMapping = _pendingCreation == null ? mapping : null;
      send = true;
    } catch (error) {
      if (_current) setState(() => _error = _message(error));
    } finally {
      if (_current) setState(() => _busy = false);
    }
    if (_current && send) await _saveMapping();
  }

  Future<void> _newAccount() async {
    if (!_current || _busy || _unknown || _newAccountOpen) return;
    _newAccountOpen = true;
    Map<String, dynamic>? request;
    try {
      request = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _NewChartAccountDialog(
          initial: _pendingNewAccount,
          ownerEpoch: _ownerEpoch,
          canCreate: ref
              .read(currentPermissionsProvider)
              .contains(Perm.paymentStyleCreate),
          currencies: _currencies,
        ),
      );
    } finally {
      _newAccountOpen = false;
    }
    if (!_current || request == null) return;
    _pendingNewAccount = request;
    await _saveNewAccount();
  }

  Future<void> _saveNewAccount() async {
    if (!_current || _busy || _pendingNewAccount == null) return;
    final wasUnknown = _unknown;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.post('/finance/chart', body: _pendingNewAccount);
      if (!_current) return;
      setState(() {
        _unknown = false;
        _changed = true;
        _pendingNewAccount = null;
      });
    } catch (error) {
      if (_current) {
        setState(() {
          _unknown = wasUnknown || !_rejected(error);
          _error =
              '${_message(error)}。新增内容已保留，${_unknown ? '请核对并重试原新增请求' : '请重新打开新增科目更正'}';
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
    if (_current && _pendingNewAccount == null) await _load();
  }

  Future<void> _saveMapping() async {
    if (!_current ||
        _busy ||
        (_pendingMapping == null && _pendingCreation == null)) {
      return;
    }
    final wasUnknown = _unknown;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = _pendingCreation != null
          ? await _api.post(
              '/finance/chart/$_pendingCode/create-target',
              body: _pendingCreation,
            )
          : await _api.put(
              '/finance/chart/$_pendingCode',
              body: _pendingMapping,
            );
      if (!_current) return;
      setState(() {
        _accounts = _maps(result['items']);
        _changed = true;
        _unknown = false;
        _pendingMapping = null;
        _pendingCreation = null;
        _pendingCode = null;
      });
    } catch (error) {
      if (_current) {
        setState(() {
          _unknown = wasUnknown || !_rejected(error);
          _error =
              '${_message(error)}。原代码、版本和选择已保留，${_unknown ? '请核对并重试原对应' : '请重新打开该代码更正对应'}';
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  List<Widget> get _tableActions => [
    if (widget.canEdit)
      UtenButton(
        onPressed: _busy || _unknown ? null : _newAccount,
        child: const Text('新增科目'),
      ),
    if (widget.canEdit)
      UtenButton(
        onPressed: _busy || _unknown ? null : _pick,
        child: const Text('导入科目目录'),
      ),
    UtenExportButton(
      endpoint: '/finance/reports/export',
      report: 'gl/chart-template',
      queryParams: const {},
      requiredPermission: Perm.financeReportExport,
      filename: '科目目录导入模板',
      label: '下载导入模板',
      enabled: !_busy && !_unknown,
    ),
    UtenExportButton(
      endpoint: '/finance/reports/export',
      report: 'gl/chart-codes',
      queryParams: const {},
      requiredPermission: Perm.financeReportExport,
      filename: '科目代码对应',
      label: '导出当前对应',
      enabled: !_busy && !_unknown,
    ),
    if (ref.read(currentPermissionsProvider).contains(Perm.financeReportView) &&
        ref.read(currentPermissionsProvider).contains(Perm.financeViewAll))
      UtenButton(
        type: UtenButtonType.secondary,
        onPressed: _busy || _unknown
            ? null
            : () async {
                if (!_current) return;
                await showFinanceNativePostingAccountsDialog(context);
                if (_current) await _load();
              },
        child: const Text('业务单据科目对应'),
      ),
    UtenButton(
      type: UtenButtonType.secondary,
      onPressed: _busy || _unknown ? null : _load,
      child: const Text('刷新/恢复批次'),
    ),
  ];
  Widget _directoryTable() {
    final visible = _accounts
        .where(
          (row) => '${row['code']} ${row['name']}'.contains(_keyword.trim()),
        )
        .toList();
    return MasterDataTableView<Map<String, dynamic>>(
      tableKey: 'finance.chart.directory',
      virtualized: true,
      expensiveRowMounts: false,
      showPaginationControls: false,
      columns: [
        MasterColumnDef(
          key: 'code',
          label: '科目编码',
          width: 120,
          value: (row) => row['code']?.toString(),
          sortable: true,
          filterFromRows: true,
        ),
        MasterColumnDef(
          key: 'name',
          label: '科目名称',
          width: 230,
          value: (row) => row['name']?.toString(),
          sortable: true,
          filterFromRows: true,
        ),
        MasterColumnDef(
          key: 'currencyName',
          label: '外币名称',
          width: 100,
          value: (row) => row['currencyName']?.toString(),
          filterFromRows: true,
        ),
        MasterColumnDef(
          key: 'classification',
          label: '类别',
          width: 90,
          value: (row) =>
              FinanceRequirementNames
                  .chartClassificationLabels[row['classification']] ??
              '待维护',
          filterFromRows: true,
        ),
        MasterColumnDef(
          key: 'targets',
          label: '对应科目',
          width: 280,
          value: (row) => _maps(
            row['targets'],
          ).map((target) => '${target['code']} ${target['name']}').join('；'),
        ),
        if (widget.canEdit)
          MasterColumnDef(
            key: 'actions',
            label: '操作',
            width: 160,
            exportable: false,
            value: (_) => '',
            cellBuilder: (_, row) => UtenButton(
              type: UtenButtonType.secondary,
              size: UtenButtonSize.small,
              onPressed: _busy || _unknown ? null : () => _edit(row),
              child: const Text('对应科目/报表'),
            ),
          ),
      ],
      items: visible,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      toolbarLeadingActions: [
        SizedBox(
          width: 220,
          child: UtenSearchBar(
            hint: '搜索科目编码或名称',
            initialValue: _keyword,
            onChanged: (value) => setState(() => _keyword = value),
          ),
        ),
      ],
      toolbarActions: _tableActions,
      onRowDoubleTap: widget.canEdit && !_busy && !_unknown ? _edit : null,
    );
  }

  Widget _previewTable(
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> issues,
  ) => MasterDataTableView<Map<String, dynamic>>(
    tableKey: issues.isEmpty
        ? 'finance.chart.import.preview'
        : 'finance.chart.import.issues',
    virtualized: true,
    expensiveRowMounts: false,
    showPaginationControls: false,
    showColumnChooser: false,
    columns: issues.isEmpty
        ? [
            MasterColumnDef(
              key: 'code',
              label: '科目编码',
              width: 120,
              value: (row) => row['code']?.toString(),
            ),
            MasterColumnDef(
              key: 'name',
              label: '科目名称',
              width: 230,
              value: (row) => row['name']?.toString(),
            ),
            MasterColumnDef(
              key: 'currencyName',
              label: '外币名称',
              width: 100,
              value: (row) => row['currencyName']?.toString(),
            ),
            for (final label in const [
              '期初借方',
              '期初贷方',
              '本期发生借方',
              '本期发生贷方',
              '期末借方',
              '期末贷方',
            ])
              MasterColumnDef(
                key: label,
                label: label,
                width: 120,
                type: 'money',
                value: (_) => '',
              ),
          ]
        : [
            MasterColumnDef(
              key: 'sourceRow',
              label: '原行',
              width: 80,
              value: (row) => row['sourceRow']?.toString(),
            ),
            MasterColumnDef(
              key: 'field',
              label: '字段',
              width: 130,
              value: (row) => row['field']?.toString(),
            ),
            MasterColumnDef(
              key: 'message',
              label: '错误说明',
              width: 460,
              value: (row) => row['message']?.toString(),
            ),
          ],
    items: issues.isEmpty ? rows : issues,
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    toolbarActions: _tableActions,
  );
  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _ownerEpoch) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(context, _changed),

        title: const Text('访问范围已变化'),
        content: const Text('请关闭后以当前账号重新打开科目对应。原导入批次保留在所属账号。'),
      );
    }
    final sourceRows = _maps(_preview?['rows']),
        issues = _maps(_preview?['issues']);
    return PopScope(
      canPop: !_busy && !_unknown,
      child: UtenAlertDialog(
        showCloseButton: true,
        onClose: _busy || _unknown
            ? null
            : () => Navigator.pop(context, _changed),
        closeEnabled: !(_busy || _unknown),

        maxWidth: 1140,
        scrollable: false,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(FinanceRequirementNames.chartCodes)),
            UtenFieldHintIcon(
              info: '按财务会计软件的原代码和顺序建立目录。已有核算科目可对应，缺少的可补建；目录导入不带入余额或生成分录。',
            ),
          ],
        ),
        content: SizedBox(
          width: 1100,
          height: MediaQuery.sizeOf(context).height * .68,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_unknown)
                UtenButton(
                  onPressed: _busy
                      ? null
                      : _pendingNewAccount != null
                      ? _saveNewAccount
                      : (_pendingMapping != null || _pendingCreation != null)
                      ? _saveMapping
                      : _apply,
                  child: Text(
                    _pendingNewAccount != null
                        ? '核对并重试原新增请求'
                        : (_pendingMapping != null || _pendingCreation != null)
                        ? '核对并重试原对应'
                        : '核对并重试原批次',
                  ),
                ),
              if (_busy)
                const UtenBusyOverlay(
                  title: '正在处理科目目录',
                  showDoNotLeaveHint: false,
                ),
              if (_preview == null &&
                  !_unknown &&
                  _recent.any((batch) => batch['appliedAt'] == null))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: UtenDropdownField(
                    label: '恢复导入批次',
                    value: null,
                    items: [
                      for (final batch in _recent.where(
                        (row) => row['appliedAt'] == null,
                      ))
                        UtenDropdownItem(
                          value: batch['importId']?.toString(),
                          label: batch['sourceName']?.toString() ?? '',
                        ),
                    ],
                    enabled: !_busy,
                    onChanged: (id) {
                      final batch = _recent
                          .where((row) => row['importId'] == id)
                          .firstOrNull;
                      if (batch != null) _restore(batch);
                    },
                  ),
                ),
              const SizedBox(height: 8),
              if (_preview != null)
                Text(
                  '${_preview!['sourceName']}：${sourceRows.length}条科目，${issues.length}项错误',
                ),
              Expanded(
                child: _preview == null
                    ? _directoryTable()
                    : _previewTable(sourceRows, issues),
              ),
              if (_preview != null)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (widget.canEdit &&
                        issues.isEmpty &&
                        _preview!['applied'] != true &&
                        !_unknown)
                      UtenButton(
                        onPressed: _busy ? null : _apply,
                        child: const Text('确认导入科目目录'),
                      ),
                    if (!_unknown)
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: _busy
                            ? null
                            : () => setState(() => _preview = null),
                        child: const Text('返回对应清单'),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewChartAccountDialog extends ConsumerStatefulWidget {
  const _NewChartAccountDialog({
    required this.initial,
    required this.ownerEpoch,
    required this.canCreate,
    required this.currencies,
  });
  final Map<String, dynamic>? initial;
  final int ownerEpoch;
  final bool canCreate;
  final List<Map<String, dynamic>> currencies;
  @override
  ConsumerState<_NewChartAccountDialog> createState() =>
      _NewChartAccountDialogState();
}

class _NewChartAccountDialogState
    extends ConsumerState<_NewChartAccountDialog> {
  final _form = GlobalKey<FormState>();
  late final _code = TextEditingController(
    text: widget.initial?['code']?.toString() ?? '',
  );
  late final _name = TextEditingController(
    text: widget.initial?['name']?.toString() ?? '',
  );
  late final _currency = TextEditingController(
    text: widget.initial?['currencyName']?.toString() ?? '',
  );
  late final _reference = TextEditingController(
    text: widget.initial?['sourceReference']?.toString() ?? '',
  );
  late final String _requestId =
      widget.initial?['requestId']?.toString() ?? const Uuid().v4();
  late String? _category = widget.initial?['category']?.toString();
  late String? _classification = widget.initial?['classification']?.toString();
  bool _classificationMissing = false;
  String? get _baseCurrencyId => widget.currencies
      .where((row) => row['baseCurrency'] == true)
      .firstOrNull?['id']
      ?.toString();
  late String? _currencyId =
      widget.initial?['currencyId']?.toString() ?? _baseCurrencyId;
  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _currency.dispose();
    _reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(exportContextEpochProvider) == widget.ownerEpoch;
    return UtenAlertDialog(
      title: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text('新增科目')),
          UtenFieldHintIcon(
            info:
                '填写财务实际使用的代码和名称。新增后在“对应科目/报表”设置取数归属；损益科目结转后余额为零，本期发生额仍参与利润计算。',
          ),
        ],
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UtenInput(
                  controller: _code,
                  enabled: current,
                  label: '科目编码',
                  required: true,
                  validator: (value) =>
                      RegExp(r'^[0-9]{1,32}$').hasMatch(value ?? '')
                      ? null
                      : '请输入完整数字文本代码',
                ),
                UtenInput(
                  controller: _name,
                  enabled: current,
                  label: '科目名称',
                  required: true,
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ||
                          (value ?? '').trim().length > 240
                      ? '请填写不超过240字的科目名称'
                      : null,
                ),
                UtenInput(
                  controller: _currency,
                  enabled: current,
                  label: '外币名称',
                  info: '本币科目可留空；这是科目属性',
                  validator: (value) =>
                      (value ?? '').length > 80 ? '外币名称不超过80字' : null,
                  onChanged: (value) {
                    if (current) {
                      setState(
                        () => _currencyId = value.trim().isEmpty
                            ? _baseCurrencyId
                            : null,
                      );
                    }
                  },
                ),
                const SizedBox(height: 12),
                UtenDropdownField(
                  label: '财务类别',
                  required: true,
                  value: _classification,
                  enabled: current,
                  errorMessage: _classificationMissing ? '请选择原表财务类别' : null,
                  items: [
                    for (final entry
                        in FinanceRequirementNames
                            .chartClassificationLabels
                            .entries)
                      UtenDropdownItem(value: entry.key, label: entry.value),
                  ],
                  onChanged: (value) {
                    if (current) {
                      setState(() {
                        _classification = value;
                        _classificationMissing = false;
                      });
                    }
                  },
                ),
                if (widget.canCreate) ...[
                  const SizedBox(height: 12),
                  UtenDropdownField(
                    label: '同时补建核算类别',
                    value: _category,
                    items: const [
                      UtenDropdownItem(value: 'ACCOUNT', label: '资产 / 未结转成本余额'),
                      UtenDropdownItem(value: 'LIABILITY', label: '负债'),
                      UtenDropdownItem(value: 'EQUITY', label: '权益'),
                      UtenDropdownItem(value: 'INCOME', label: '收入'),
                      UtenDropdownItem(value: 'EXPENSE', label: '费用 / 损益支出'),
                    ],
                    onChanged: (value) {
                      if (current) setState(() => _category = value);
                    },
                  ),
                  TextButton(
                    onPressed: current
                        ? () => setState(() => _category = null)
                        : null,
                    child: const Text('仅新增目录，稍后对应已有核算科目'),
                  ),
                ],
                UtenInput(
                  controller: _reference,
                  enabled: current,
                  maxLines: 4,
                  label: '新增依据',
                  required: true,
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ||
                          (value ?? '').trim().length > 1000
                      ? '请填写不超过1000字的来源或新增依据'
                      : null,
                ),
                const SizedBox(height: 12),
                UtenDropdownField(
                  label: '核算币别',
                  value: _currencyId,
                  enabled: current,
                  info: '本币科目使用系统明确的本位币；外币属性请对应真实币别，不按名称或旧编号猜测。',
                  items: [
                    for (final row in widget.currencies)
                      UtenDropdownItem(
                        value: row['id']?.toString(),
                        label:
                            '${row['name']}（${row['code']}）${row['baseCurrency'] == true ? ' · 本位币' : ''}',
                      ),
                  ],
                  onChanged: (value) {
                    if (current) setState(() => _currencyId = value);
                  },
                ),
                if (!current) const Text('访问范围已变化，请关闭后重新打开'),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        UtenButton(
          onPressed: !current
              ? null
              : () {
                  if (_form.currentState?.validate() != true) return;
                  if (_classification == null) {
                    setState(() => _classificationMissing = true);
                    return;
                  }
                  Navigator.pop(context, <String, dynamic>{
                    'requestId': _requestId,
                    'code': _code.text,
                    'name': _name.text.trim(),
                    'currencyName': _currency.text.trim(),
                    'category': _category,
                    'classification': _classification,
                    'currencyId': _currencyId,
                    'sourceReference': _reference.text.trim(),
                  });
                },
          child: const Text('新增科目'),
        ),
      ],
    );
  }
}

class _ChartMappingDialog extends ConsumerStatefulWidget {
  const _ChartMappingDialog({
    required this.account,
    required this.candidates,
    required this.lines,
    required this.ownerEpoch,
    required this.canCreate,
    required this.currencies,
  });
  final Map<String, dynamic> account;
  final List<GlReportLineCandidate> candidates;
  final List<GlReportLineBinding> lines;
  final int ownerEpoch;
  final bool canCreate;
  final List<Map<String, dynamic>> currencies;
  @override
  ConsumerState<_ChartMappingDialog> createState() =>
      _ChartMappingDialogState();
}

class _ChartMappingDialogState extends ConsumerState<_ChartMappingDialog> {
  late Set<String> _ids;
  String? _balance, _profit;
  String? _createCategory;
  String? _classification;
  String? _currencyId;
  @override
  void initState() {
    super.initState();
    _classification = widget.account['classification']?.toString();
    _currencyId = widget.account['currencyId']?.toString();
    _createCategory = widget.account['creationCategory']?.toString();
    _ids = _maps(
      widget.account['targets'],
    ).map((r) => r['id'].toString()).toSet();
    final keys = (widget.account['lineKeys'] as List<dynamic>? ?? const [])
        .map((v) => v.toString())
        .toList();
    _balance = keys.where((k) => k.startsWith('BS_')).firstOrNull;
    _profit = keys.where((k) => !k.startsWith('BS_')).firstOrNull;
  }

  Future<void> _choose() async {
    final selected = await showGlReportTargetPicker(
      context,
      title: '对应系统科目',
      candidates: widget.candidates,
      initial: _ids,
    );
    if (mounted && selected != null) {
      setState(() {
        _ids = selected;
        _balance = null;
        _profit = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != widget.ownerEpoch) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(context),

        title: const Text('访问范围已变化'),
      );
    }
    return UtenAlertDialog(
      maxWidth: 760,
      title: Text('${widget.account['code']} ${widget.account['name']}'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '一个系统末级科目只能对应一个财务代码。报表父项/其中项分别选择，不重复归集。原有手工取数设置不会被静默删除。',
              ),
              const SizedBox(height: 12),
              UtenDropdownField(
                label: '财务类别',
                value: _classification,
                items: [
                  for (final entry
                      in FinanceRequirementNames
                          .chartClassificationLabels
                          .entries)
                    UtenDropdownItem(value: entry.key, label: entry.value),
                ],
                onChanged: (value) => setState(() => _classification = value),
              ),
              const SizedBox(height: 12),
              UtenDropdownField(
                label: '核算币别',
                value: _currencyId,
                info:
                    '原外币名称：${widget.account['currencyName'] ?? ''}。该属性不替代实际原币金额的计量单位。',
                items: [
                  for (final row in widget.currencies)
                    UtenDropdownItem(
                      value: row['id']?.toString(),
                      label:
                          '${row['name']}（${row['code']}）${row['baseCurrency'] == true ? ' · 本位币' : ''}',
                    ),
                ],
                onChanged: (value) => setState(() => _currencyId = value),
              ),
              const SizedBox(height: 12),
              UtenButton(
                onPressed: _choose,
                child: Text('选择系统科目（${_ids.length}）'),
              ),
              for (final target in widget.candidates.where(
                (c) => _ids.contains(c.id),
              ))
                Text(target.label),
              if (widget.canCreate && _ids.isEmpty) ...[
                const SizedBox(height: 12),
                const Text('没有对应核算科目时可补建。请核对类别；补建不代表历史余额已接续。'),
                UtenDropdownField(
                  label: '补建核算类别',
                  value: _createCategory,
                  items: const [
                    UtenDropdownItem(value: 'ACCOUNT', label: '资产 / 未结转成本余额'),
                    UtenDropdownItem(value: 'LIABILITY', label: '负债'),
                    UtenDropdownItem(value: 'EQUITY', label: '权益'),
                    UtenDropdownItem(value: 'INCOME', label: '收入'),
                    UtenDropdownItem(value: 'EXPENSE', label: '费用 / 已结转损益'),
                  ],
                  onChanged: (v) => setState(() => _createCategory = v),
                ),
              ],
              const SizedBox(height: 12),
              UtenDropdownField(
                label: '资产负债表项目',
                value: _balance,
                items: [
                  for (final line in widget.lines.where(
                    (l) => l.sheet == 'BALANCE',
                  ))
                    UtenDropdownItem(value: line.lineKey, label: line.label),
                ],
                onChanged: (v) => setState(() => _balance = v),
              ),
              const SizedBox(height: 12),
              UtenDropdownField(
                label: '利润表项目',
                value: _profit,
                items: [
                  for (final line in widget.lines.where(
                    (l) => l.sheet == 'PROFIT',
                  ))
                    UtenDropdownItem(value: line.lineKey, label: line.label),
                ],
                onChanged: (v) => setState(() => _profit = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        if (widget.canCreate && _ids.isEmpty && _createCategory != null)
          UtenButton(
            onPressed: () => Navigator.pop(context, <String, dynamic>{
              'expectedVersion': widget.account['version'],
              'category': _createCategory,
              'classification': _classification,
              'currencyId': _currencyId,
            }),
            child: const Text('补建并对应此科目'),
          ),
        UtenButton(
          onPressed: () => Navigator.pop(context, <String, dynamic>{
            'expectedVersion': widget.account['version'],
            'styleIds': _ids.toList(),
            'balanceLineKey': _balance,
            'profitLineKey': _profit,
            'classification': _classification,
            'currencyId': _currencyId,
          }),
          child: const Text('保存对应'),
        ),
      ],
    );
  }
}
