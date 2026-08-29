import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/inputs/uten_search_bar.dart';
import '../../../../components/layout/uten_adaptive_panel.dart';
import '../../../../components/layout/uten_h_scroll_area.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/network/latest_request_guard.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../core/utils/currency_display.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../models/supplier_settlement.dart';
import '../repositories/supplier_settlement_repository.dart';
import 'supplier_settlement_actions.dart';

class SupplierSettlementPanel extends ConsumerStatefulWidget {
  const SupplierSettlementPanel({super.key});

  @override
  ConsumerState<SupplierSettlementPanel> createState() =>
      _SupplierSettlementPanelState();
}

class _SupplierSettlementPanelState
    extends ConsumerState<SupplierSettlementPanel> {
  final _requests = LatestRequestGuard();
  SupplierSettlementPageResult? _result;
  bool _loading = false;
  bool _writing = false;
  String? _error;
  String _keyword = '';
  String? _status;
  int _page = 1;

  bool get _canCreate => ref
      .read(currentPermissionsProvider)
      .contains(Perm.supplierSettlementCreate);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _load([int? requestedPage]) async {
    final generation = _requests.begin();
    final page = requestedPage ?? _page;
    setState(() {
      _page = page;
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(supplierSettlementRepositoryProvider)
          .list(status: _status, keyword: _keyword, page: page);
      if (!mounted || !_requests.isCurrent(generation)) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } on ApiException catch (error) {
      _fail(generation, error.message);
    } catch (_) {
      _fail(generation, '服务暂不可用，请稍后重试');
    }
  }

  void _fail(int generation, String message) {
    if (!mounted || !_requests.isCurrent(generation)) return;
    setState(() {
      _loading = false;
      _error = message;
    });
    context.appError('加载月结批次失败：$message');
  }

  Future<void> _create() async {
    if (_writing) return;
    final draft = await showSupplierSettlementCreatePanel(context: context);
    if (draft == null || !mounted) return;
    setState(() => _writing = true);
    try {
      final detail = await ref
          .read(supplierSettlementRepositoryProvider)
          .freeze(
            supplierId: draft.supplierId,
            currencyId: draft.currencyId,
            periodStart: draft.periodStart,
            settlementMethodId: draft.settlementMethodId,
          );
      if (!mounted) return;
      setState(() => _writing = false);
      context.appSuccess('月结批次 ${detail.summary.batchNo ?? ''} 已冻结');
      await _load(1);
      if (mounted) await _open(detail.summary);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _writing = false);
      context.appError(error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _writing = false);
      context.appError('生成月结批次失败，请稍后重试');
    }
  }

  Future<void> _open(SupplierSettlementSummary item) async {
    await showUtenAdaptivePanel<void>(
      context: context,
      drawerWidth: 980,
      compactHeightFactor: 0.96,
      panelElevation: 12,
      builder: (_) => SupplierSettlementDetailPanel(
        batchId: item.id,
        onChanged: () => _load(),
      ),
    );
    if (mounted) await _load();
  }

  List<MasterColumnDef<SupplierSettlementSummary>> get _columns => [
    MasterColumnDef(
      key: 'batchNo',
      label: '批次号',
      width: 170,
      value: (item) => item.batchNo,
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '供应商',
      width: 210,
      value: (item) => [
        item.supplierCode,
        item.supplierName,
      ].whereType<String>().where((value) => value.isNotEmpty).join(' · '),
    ),
    MasterColumnDef(
      key: 'currencyCode',
      label: '币种',
      width: 80,
      value: (item) =>
          financeCurrencyDisplayLabel(
            name: item.currencyName,
            code: item.currencyCode,
          ) ??
          '原币',
    ),
    MasterColumnDef(
      key: 'periodStart',
      label: '月份',
      width: 100,
      type: 'date',
      value: (item) => item.periodStart?.substring(0, 7),
    ),
    MasterColumnDef(
      key: 'dueDate',
      label: '到期日',
      width: 110,
      type: 'date',
      value: (item) => item.dueDate,
    ),
    MasterColumnDef(
      key: 'openingBalanceOriginal',
      label: '期初(原币)',
      width: 120,
      type: 'money',
      value: (item) => item.openingBalanceOriginal,
    ),
    MasterColumnDef(
      key: 'periodPostedOriginal',
      label: '本期立账/红冲',
      width: 130,
      type: 'money',
      value: (item) => item.periodPostedOriginal,
    ),
    MasterColumnDef(
      key: 'periodPaidOriginal',
      label: '账面付款',
      width: 120,
      type: 'money',
      value: (item) => item.periodPaidOriginal,
    ),
    MasterColumnDef(
      key: 'periodOffsetOriginal',
      label: '抵销',
      width: 110,
      type: 'money',
      value: (item) => item.periodOffsetOriginal,
    ),
    MasterColumnDef(
      key: 'closingBalanceOriginal',
      label: '期末(原币)',
      width: 120,
      type: 'money',
      value: (item) => item.closingBalanceOriginal,
    ),
    MasterColumnDef(
      key: 'lineCount',
      label: '行数',
      width: 70,
      type: 'number',
      value: (item) => item.lineCount.toString(),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 130,
      value: (item) => item.statusLabel,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _result?.total ?? 0;
    return Column(
      children: [
        Row(
          children: [
            Icon(
              Icons.calendar_month_outlined,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                '供应商月结批次 ($total)',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (_canCreate)
              UtenButton(
                key: const ValueKey('supplier-settlement-create'),
                icon: Icons.add_rounded,
                isLoading: _writing,
                onPressed: _writing ? null : _create,
                child: const Text('生成月结批次'),
              ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        UtenSearchBar(
          key: const ValueKey('supplier-settlement-search'),
          hint: '搜索批次号、供应商编号或名称',
          initialValue: _keyword,
          onChanged: (value) {
            setState(() => _keyword = value);
            _load(1);
          },
        ),
        const SizedBox(height: UtenSpacing.s8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _statusChip('全部', null),
              _statusChip('已冻结', 'FROZEN'),
              _statusChip('供应商确认', 'SUPPLIER_CONFIRMED'),
              _statusChip('公司确认', 'INTERNAL_CONFIRMED'),
              _statusChip('双方确认', 'BOTH_CONFIRMED'),
              _statusChip('争议', 'DISPUTED'),
              _statusChip('已反转', 'REVERSED'),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: MasterDataTableView<SupplierSettlementSummary>(
            primary: true,
            columns: _columns,
            items: _result?.items ?? const [],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            onRowTap: _open,
            isLoading: _loading && _result == null,
            loadingMore: _loading && _result != null,
            error: _error,
            onRetry: () => _load(),
            emptyMessage: '暂无供应商月结批次',
            currentPage: _result?.page ?? 1,
            totalPages: _result?.totalPages ?? 1,
            onPageChange: (page) => _load(page),
          ),
        ),
      ],
    );
  }

  Widget _statusChip(String label, String? value) => Padding(
    padding: const EdgeInsets.only(right: UtenSpacing.s4),
    child: ChoiceChip(
      label: Text(label),
      selected: _status == value,
      onSelected: (_) {
        setState(() => _status = value);
        _load(1);
      },
    ),
  );
}

class SupplierSettlementDetailPanel extends ConsumerStatefulWidget {
  const SupplierSettlementDetailPanel({
    super.key,
    required this.batchId,
    this.onChanged,
  });

  final String batchId;
  final VoidCallback? onChanged;

  @override
  ConsumerState<SupplierSettlementDetailPanel> createState() =>
      _SupplierSettlementDetailPanelState();
}

class _SupplierSettlementDetailPanelState
    extends ConsumerState<SupplierSettlementDetailPanel> {
  SupplierSettlementDetail? _detail;
  bool _loading = true;
  bool _writing = false;
  String? _error;

  Set<String> get _permissions => ref.read(currentPermissionsProvider);
  bool get _canConfirm => _permissions.contains(Perm.supplierSettlementConfirm);
  bool get _canDispute => _permissions.contains(Perm.supplierSettlementDispute);
  bool get _canReverse => _permissions.contains(Perm.supplierSettlementReverse);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(supplierSettlementRepositoryProvider)
          .detail(widget.batchId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    }
  }

  void _replace(SupplierSettlementDetail detail, String message) {
    setState(() {
      _detail = detail;
      _writing = false;
    });
    widget.onChanged?.call();
    context.appSuccess(message);
  }

  Future<void> _confirm({required bool supplier}) async {
    final current = _detail!;
    final draft = await showSupplierSettlementConfirmDialog(
      context: context,
      supplier: supplier,
    );
    if (draft == null || !mounted) return;
    setState(() => _writing = true);
    try {
      final repo = ref.read(supplierSettlementRepositoryProvider);
      final detail = supplier
          ? await repo.supplierConfirm(
              current.summary.id,
              expectedVersion: current.summary.version,
              reference: draft.reference!,
              note: draft.note,
            )
          : await repo.internalConfirm(
              current.summary.id,
              expectedVersion: current.summary.version,
              note: draft.note,
            );
      if (!mounted) return;
      _replace(detail, supplier ? '供应商确认已登记' : '公司内部确认已完成');
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _writing = false);
      context.appError(error.message);
    }
  }

  Future<void> _reasonAction({required bool reverse}) async {
    final current = _detail!;
    final reason = await showSupplierSettlementReasonDialog(
      context: context,
      title: reverse ? '反转月结批次' : '登记月结争议',
      label: reverse ? '反转原因(必填)' : '争议原因(必填)',
    );
    if (reason == null || !mounted) return;
    setState(() => _writing = true);
    try {
      final repo = ref.read(supplierSettlementRepositoryProvider);
      final detail = reverse
          ? await repo.reverse(
              current.summary.id,
              expectedVersion: current.summary.version,
              reason: reason,
            )
          : await repo.dispute(
              current.summary.id,
              expectedVersion: current.summary.version,
              reason: reason,
            );
      if (!mounted) return;
      _replace(detail, reverse ? '月结批次已反转' : '月结争议已登记');
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _writing = false);
      context.appError(error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('供应商月结详情'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: _writing ? null : () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading || _writing ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
          : _error != null
          ? Center(child: Text(_error!))
          : _body(),
      bottomNavigationBar: _detail == null ? null : _actions(),
    );
  }

  Widget _body() {
    final detail = _detail!;
    final summary = detail.summary;
    final theme = Theme.of(context);
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Wrap(
                spacing: UtenSpacing.s16,
                runSpacing: UtenSpacing.s8,
                children: [
                  _kv(theme, '批次号', summary.batchNo),
                  _kv(theme, '供应商', summary.supplierName),
                  _kv(theme, '月份', summary.periodStart?.substring(0, 7)),
                  _kv(theme, '到期日(服务端)', summary.dueDate),
                  _kv(theme, '状态', summary.statusLabel),
                  _kv(theme, '期初原币', summary.openingBalanceOriginal),
                  _kv(theme, '本期立账/红冲', summary.periodPostedOriginal),
                  _kv(theme, '账面付款', summary.periodPaidOriginal),
                  _kv(theme, '抵销', summary.periodOffsetOriginal),
                  _kv(theme, '期末原币', summary.closingBalanceOriginal),
                  _kv(theme, '行数', summary.lineCount.toString()),
                  _kv(theme, '版本', summary.version.toString()),
                ],
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          SelectableText(
            '快照 SHA-256：${summary.snapshotHash ?? '—'}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            '快照明细 (${detail.lines.length})',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          Card(
            child: UtenHScrollArea(
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('来源单')),
                  DataColumn(label: Text('类型')),
                  DataColumn(label: Text('期初'), numeric: true),
                  DataColumn(label: Text('本期立账/红冲'), numeric: true),
                  DataColumn(label: Text('账面付款'), numeric: true),
                  DataColumn(label: Text('抵销'), numeric: true),
                  DataColumn(label: Text('期末'), numeric: true),
                  DataColumn(label: Text('到期日')),
                ],
                rows: [
                  for (final line in detail.lines)
                    DataRow(
                      cells: [
                        DataCell(Text(line.sourceDocNo ?? '—')),
                        DataCell(Text(line.openItemKind ?? '—')),
                        DataCell(Text(line.openingBalanceOriginal ?? '—')),
                        DataCell(Text(line.periodPostedOriginal ?? '—')),
                        DataCell(Text(line.periodPaidOriginal ?? '—')),
                        DataCell(Text(line.periodOffsetOriginal ?? '—')),
                        DataCell(Text(line.closingBalanceOriginal ?? '—')),
                        DataCell(Text(line.dueDate ?? '—')),
                      ],
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            '处理事件 (${detail.events.length})',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          for (final event in detail.events)
            ListTile(
              dense: true,
              leading: const Icon(Icons.radio_button_checked, size: 14),
              title: Text(event.type ?? '事件'),
              subtitle: Text(event.reason ?? '—'),
              trailing: Text(event.createdAt ?? '—'),
            ),
        ],
      ),
    );
  }

  Widget _kv(ThemeData theme, String label, String? value) => SizedBox(
    width: 210,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(value?.isNotEmpty == true ? value! : '—'),
      ],
    ),
  );

  Widget? _actions() {
    final summary = _detail!.summary;
    final children = <Widget>[];
    if (_canReverse && summary.canReverse) {
      children.add(
        UtenButton(
          type: UtenButtonType.danger,
          icon: Icons.undo_outlined,
          isLoading: _writing,
          onPressed: _writing ? null : () => _reasonAction(reverse: true),
          child: const Text('反转批次'),
        ),
      );
    }
    if (_canDispute && summary.canDispute) {
      children.add(
        UtenButton(
          type: UtenButtonType.tonal,
          icon: Icons.report_problem_outlined,
          isLoading: _writing,
          onPressed: _writing ? null : () => _reasonAction(reverse: false),
          child: const Text('登记争议'),
        ),
      );
    }
    if (_canConfirm && summary.canSupplierConfirm) {
      children.add(
        UtenButton(
          type: UtenButtonType.secondary,
          icon: Icons.handshake_outlined,
          isLoading: _writing,
          onPressed: _writing ? null : () => _confirm(supplier: true),
          child: const Text('供应商确认'),
        ),
      );
    }
    if (_canConfirm && summary.canInternalConfirm) {
      children.add(
        UtenButton(
          icon: Icons.fact_check_outlined,
          isLoading: _writing,
          onPressed: _writing ? null : () => _confirm(supplier: false),
          child: const Text('公司确认'),
        ),
      );
    }
    if (children.isEmpty) return null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: children,
        ),
      ),
    );
  }
}
