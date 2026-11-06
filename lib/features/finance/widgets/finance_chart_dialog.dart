import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/search/keyword_search.dart';
import '../../../shared/platform_tables/table_column_projection.dart';
import '../../basic_data/models/master_facet.dart';
import 'finance_chart_import_workbench.dart';
import 'finance_native_posting_accounts_dialog.dart';
import '../config/finance_requirement_names.dart';
import '../shared/finance_workbench_panel.dart';
import 'finance_chart_metadata_dialog.dart';
import 'finance_chart_command_dialog.dart';
import 'finance_durable_command_dialog.dart';
import '../../../components/feedback/uten_context_menu.dart';

List<Map<String, dynamic>> _maps(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map<String, dynamic>) row,
];

Future<bool> showFinanceChartDialog(
  BuildContext context, {
  required bool canEdit,
}) async =>
    await showFinanceWorkbenchPanel<bool>(
      context: context,
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
  List<Map<String, dynamic>> _accounts = [], _currencies = [];
  String? _error;
  String _keyword = '';
  final Map<String, String?> _directoryFilters = {};
  String? _directorySort;
  bool _directoryAscending = true;
  bool _busy = false, _changed = false;
  bool _chartCommandOpen = false, _mappingMenuOpen = false;
  int _mappingMenuEpoch = 0;
  bool _metadataEditorOpen = false;
  final _mappingMenu = UtenContextMenuController();
  bool get _locked =>
      _busy || _chartCommandOpen || _mappingMenuOpen || _metadataEditorOpen;
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
      ]);
      if (!_current) return;
      setState(() {
        _accounts = _maps(results[0]['items']);
        _currencies = _maps(results[1]['currencies']);
      });
    } catch (error) {
      if (_current) setState(() => _error = _message(error));
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  String _message(Object error) =>
      error is ApiException ? error.message : '操作未完成，请核对网络后重试';
  Future<void> _pick() async {
    if (!_current || _locked) return;
    setState(() => _chartCommandOpen = true);
    try {
      final changed = await showFinanceChartImportWorkbench(context);
      if (!_current || !changed) return;
      _changed = true;
      await _load();
    } finally {
      if (mounted) setState(() => _chartCommandOpen = false);
    }
  }

  Future<void> _runChartCommand(
    FinanceDurableOperation operation, {
    Map<String, dynamic>? account,
  }) async {
    if (!_current || _locked) return;
    setState(() => _chartCommandOpen = true);
    try {
      final result = await showFinanceChartCommand(
        context,
        operation: operation,
        code: operation == FinanceDurableOperation.chartAccountCreate
            ? ''
            : account!['code'].toString(),
        account: account,
        currencies: _currencies,
      );
      if (!_current || result?['outcome'] != 'SUCCEEDED') return;
      _changed = true;
      await _load();
    } catch (error) {
      if (_current) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _chartCommandOpen = false);
    }
  }

  Future<void> _edit(
    Map<String, dynamic> account, {
    BuildContext? anchor,
  }) async {
    if (!_current || _locked) return;
    final canCreate = ref
        .read(currentPermissionsProvider)
        .contains(Perm.paymentStyleCreate);
    if (anchor == null || !canCreate || _maps(account['targets']).isNotEmpty) {
      await _runChartCommand(
        FinanceDurableOperation.chartMappingReplace,
        account: account,
      );
      return;
    }
    final box = anchor.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final menuEpoch = ++_mappingMenuEpoch;
    setState(() => _mappingMenuOpen = true);
    Future<void> choose(FinanceDurableOperation operation) async {
      if (!_current || !_mappingMenuOpen || menuEpoch != _mappingMenuEpoch) {
        return;
      }
      setState(() => _mappingMenuOpen = false);
      await _runChartCommand(operation, account: account);
    }

    try {
      await showUtenContextMenu(
        context,
        controller: _mappingMenu,
        globalPosition: box.localToGlobal(Offset(0, box.size.height)),
        entries: [
          UtenMenuItem(
            label: '对应已有系统科目',
            onTap: () => choose(FinanceDurableOperation.chartMappingReplace),
          ),
          UtenMenuItem(
            label: '补建并对应此科目',
            onTap: () => choose(FinanceDurableOperation.chartTargetCreate),
          ),
        ],
      );
    } finally {
      if (mounted && menuEpoch == _mappingMenuEpoch) {
        setState(() => _mappingMenuOpen = false);
      }
    }
  }

  Future<void> _newAccount() =>
      _runChartCommand(FinanceDurableOperation.chartAccountCreate);

  @override
  void deactivate() {
    _mappingMenu.dismiss();
    _mappingMenuOpen = false;
    _mappingMenuEpoch++;
    super.deactivate();
  }

  @override
  void dispose() {
    _mappingMenu.dismiss();
    _mappingMenuEpoch++;
    super.dispose();
  }

  Future<void> _editMetadata(Map<String, dynamic> account) async {
    if (!_current || _locked) return;
    _metadataEditorOpen = true;
    try {
      final changed = await showFinanceChartMetadataDialog(
        context,
        code: account['code'].toString(),
        account: account,
      );
      if (!_current || !changed) return;
      _changed = true;
      await _load();
    } finally {
      _metadataEditorOpen = false;
    }
  }

  void _closeDirectory() {
    if (!mounted || _current && (_locked)) {
      return;
    }
    Navigator.pop(context, _changed);
  }

  List<Widget> get _tableActions => [
    if (widget.canEdit)
      UtenButton(
        onPressed: _locked ? null : _newAccount,
        child: const Text('新增科目'),
      ),
    if (widget.canEdit)
      UtenButton(
        onPressed: _locked ? null : _pick,
        child: const Text('导入科目目录'),
      ),
    UtenExportButton(
      endpoint: '/finance/reports/export',
      report: 'gl/chart-template',
      showOutputScope: false,
      frozenProjection: const TableColumnProjection(
        tableKey: 'finance.chart.import.template',
        columns: [
          TableProjectedColumn(
            key: 'code',
            label: '科目编码',
            width: 120,
            type: 'text',
          ),
          TableProjectedColumn(
            key: 'name',
            label: '科目名称',
            width: 230,
            type: 'text',
          ),
          TableProjectedColumn(
            key: 'currency',
            label: '外币名称',
            width: 100,
            type: 'text',
          ),
          TableProjectedColumn(
            key: 'd0',
            label: '期初借方',
            width: 120,
            type: 'money',
          ),
          TableProjectedColumn(
            key: 'c0',
            label: '期初贷方',
            width: 120,
            type: 'money',
          ),
          TableProjectedColumn(
            key: 'd',
            label: '本期发生借方',
            width: 120,
            type: 'money',
          ),
          TableProjectedColumn(
            key: 'c',
            label: '本期发生贷方',
            width: 120,
            type: 'money',
          ),
          TableProjectedColumn(
            key: 'd1',
            label: '期末借方',
            width: 120,
            type: 'money',
          ),
          TableProjectedColumn(
            key: 'c1',
            label: '期末贷方',
            width: 120,
            type: 'money',
          ),
        ],
      ),
      queryParams: const {},
      requiredPermission: Perm.financeReportExport,
      filename: '科目目录导入模板',
      label: '下载导入模板',
      enabled: !_locked,
    ),
    UtenExportButton(
      endpoint: '/finance/reports/export',
      report: 'gl/chart-directory',
      tableKey: 'finance.chart.directory',
      queryParams: {
        if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
        for (final entry in _directoryFilters.entries)
          if (entry.value?.isNotEmpty ?? false) 'f.${entry.key}': entry.value,
        'sort': ?_directorySort,
        if (_directorySort != null)
          'order': _directoryAscending ? 'asc' : 'desc',
      },
      requiredPermission: Perm.financeReportExport,
      filename: '科目代码对应',
      label: '导出当前对应',
      enabled: !_locked,
    ),
    if (ref.read(currentPermissionsProvider).contains(Perm.financeReportView) &&
        ref.read(currentPermissionsProvider).contains(Perm.financeViewAll))
      UtenButton(
        type: UtenButtonType.secondary,
        onPressed: _locked
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
      onPressed: _locked ? null : _load,
      child: const Text('刷新/恢复批次'),
    ),
  ];

  String? _directoryValue(Map<String, dynamic> row, String key) {
    final value = switch (key) {
      'classification' =>
        FinanceRequirementNames
                .chartClassificationLabels[row['classification']] ??
            '待维护',
      'targets' => _maps(
        row['targets'],
      ).map((target) => '${target['code']} ${target['name']}').join('；'),
      _ => row[key]?.toString(),
    };
    return value?.trim().isEmpty == true ? null : value;
  }

  double _directoryActionWidth(BuildContext context) {
    var textWidth = 0.0;
    final style = DefaultTextStyle.of(
      context,
    ).style.copyWith(fontSize: 14, fontWeight: FontWeight.w600, height: 1.2);
    for (final label in const ['修改名称', '对应科目/报表']) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      textWidth += painter.width;
      painter.dispose();
    }
    // Both complete button labels, their padding, the inter-action gap and
    // cell padding belong to the same horizontal-scrolling table column.
    return (textWidth + 96).clamp(260, double.infinity).toDouble();
  }

  Widget _directoryTable() {
    final keywordRows = _accounts
        .where(
          (row) => matchesKeywordSearch([
            row['code']?.toString(),
            row['name']?.toString(),
          ], _keyword),
        )
        .toList();
    final visible = keywordRows
        .where(
          (row) => _directoryFilters.entries.every((entry) {
            final selected = entry.value;
            if (selected == null || selected.isEmpty) return true;
            final search = entry.key.startsWith('search.');
            final key = search ? entry.key.substring(7) : entry.key;
            final actual = _directoryValue(row, key);
            return search
                ? matchesKeywordSearch([actual], selected)
                : selected == kMasterFilterNullValue
                ? actual == null
                : actual == selected;
          }),
        )
        .toList();
    if (_directorySort != null) {
      visible.sort((left, right) {
        final comparison = (_directoryValue(left, _directorySort!) ?? '')
            .compareTo(_directoryValue(right, _directorySort!) ?? '');
        return _directoryAscending ? comparison : -comparison;
      });
    }
    final facets = <String, List<MasterFacetBucket>>{};
    for (final key in ['code', 'name', 'currencyName', 'classification']) {
      final counts = <String, int>{};
      for (final row in keywordRows) {
        final value = _directoryValue(row, key);
        if (value != null) counts[value] = (counts[value] ?? 0) + 1;
      }
      facets[key] = [
        for (final entry in counts.entries)
          MasterFacetBucket(value: entry.key, count: entry.value),
      ];
    }
    return MasterDataTableView<Map<String, dynamic>>(
      outputSelectionEnabled: true,
      outputIdOf: (row) => row['code']?.toString(),
      outputSelectorOf: (row) => {'code': row['code']?.toString()},
      tableKey: 'finance.chart.directory',
      paginationScope: _keyword,
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
        ),
        MasterColumnDef(
          key: 'name',
          label: '科目名称',
          width: 230,
          value: (row) => row['name']?.toString(),
          sortable: true,
        ),
        MasterColumnDef(
          key: 'currencyName',
          label: '外币名称',
          width: 100,
          value: (row) => row['currencyName']?.toString(),
        ),
        MasterColumnDef(
          key: 'classification',
          label: '类别',
          width: 90,
          value: (row) =>
              FinanceRequirementNames
                  .chartClassificationLabels[row['classification']] ??
              '待维护',
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
            width: _directoryActionWidth(context),
            minimumWidthOf: _directoryActionWidth,
            exportable: false,
            value: (_) => '',
            cellBuilder: (_, row) => Row(
              children: [
                UtenButton(
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.small,
                  onPressed: _locked ? null : () => _editMetadata(row),
                  child: const Text('修改名称'),
                ),
                const SizedBox(width: 8),
                Builder(
                  builder: (buttonContext) => UtenButton(
                    type: UtenButtonType.secondary,
                    size: UtenButtonSize.small,
                    onPressed: _locked
                        ? null
                        : () => _edit(row, anchor: buttonContext),
                    child: const Text('对应科目/报表'),
                  ),
                ),
              ],
            ),
          ),
      ],
      items: visible,
      facets: facets,
      nullCounts: {
        for (final key in facets.keys)
          key: keywordRows
              .where((row) => _directoryValue(row, key) == null)
              .length,
      },
      filters: Map.unmodifiable(_directoryFilters),
      serverColumnSearch: true,
      onFilterChanged: (key, value) => setState(() {
        if (value == null || value.isEmpty) {
          _directoryFilters.remove(key);
        } else {
          _directoryFilters[key] = value;
        }
      }),
      sortColumn: _directorySort,
      sortAscending: _directoryAscending,
      onSortChange: (key, ascending) => setState(() {
        _directorySort = key;
        _directoryAscending = ascending;
      }),
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
      onRowDoubleTap: widget.canEdit && !_locked ? _edit : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _ownerEpoch) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(context, _changed),

        title: const Text('访问范围已变化'),
        content: const Text('请关闭后以当前账号重新打开科目对应。原导入批次保留在所属账号。'),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _closeDirectory,
            child: const Text('关闭'),
          ),
        ],
      );
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeDirectory();
      },
      child: UtenAlertDialog(
        showCloseButton: true,
        onClose: _locked ? null : () => Navigator.pop(context, _changed),
        closeEnabled: !_locked,

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
              if (_busy)
                const UtenBusyOverlay(
                  title: '正在处理科目目录',
                  showDoNotLeaveHint: false,
                ),
              Expanded(child: _directoryTable()),
            ],
          ),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _locked ? null : _closeDirectory,
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
