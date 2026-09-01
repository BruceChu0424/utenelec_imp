import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../components/buttons/uten_back_button.dart';
import '../../../../components/buttons/uten_button.dart';
import '../../../../components/inputs/uten_search_bar.dart';
import '../../../../components/layout/uten_adaptive_panel.dart';
import '../../../../components/layout/uten_app_bar.dart';
import '../../../../components/layout/uten_content_container.dart';
import '../../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../../components/layout/uten_list_two_pane.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/network/latest_request_guard.dart';
import '../../../../core/router/nav_helpers.dart';
import '../../../../core/router/route_names.dart';
import '../../../../core/responsive/breakpoint.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../core/utils/currency_display.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../basic_data/models/reference_method_option.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../../../basic_data/repositories/reference_method_repository.dart';
import '../../providers/finance_name_provider.dart';
import '../../widgets/finance_table_facets.dart';
import '../models/finance_payable.dart';
import '../repositories/finance_payables_repository.dart';
import '../widgets/finance_payables_kpi_strip.dart';
import '../widgets/subcontract_loss_claim_panel.dart';
import '../widgets/supplier_credit_apply_panel.dart';
import '../widgets/supplier_settlement_panel.dart';

String financePayablesPaymentLocation(Iterable<String> payableIds) {
  final ids = payableIds.where((id) => id.trim().isNotEmpty).toSet().toList()
    ..sort();
  final path = RoutePath.financeDocNew('payments');
  if (ids.isEmpty) return path;
  return Uri(
    path: path,
    queryParameters: {'payableIds': ids.join(',')},
  ).toString();
}

enum _PayablesWorkspaceView { payables, lossClaims, supplierSettlements }

class FinancePayablesPage extends ConsumerStatefulWidget {
  const FinancePayablesPage({super.key});

  @override
  ConsumerState<FinancePayablesPage> createState() =>
      _FinancePayablesPageState();
}

class _FinancePayablesPageState extends ConsumerState<FinancePayablesPage> {
  final _requests = LatestRequestGuard();
  FinancePayablesResult? _result;
  bool _loading = false;
  String? _error;
  int _page = 1;
  String _keyword = '';
  String? _businessType;
  String? _supplierId;
  String? _status;
  String? _settlementMethodId;
  DateTime? _dateFrom;
  DateTime? _dateTo;
  DateTime? _dueFrom;
  DateTime? _dueTo;
  String? _sortKey;
  bool _sortAsc = true;
  bool _applyingOffset = false;
  Set<String> _selectedIds = <String>{};
  final Map<String, FinancePayableItem> _selectedItemsById = {};
  _PayablesWorkspaceView _workspace = _PayablesWorkspaceView.payables;

  bool get _canCreatePayment =>
      ref.read(currentPermissionsProvider).contains(Perm.financePaymentCreate);

  bool get _canViewPayables {
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.arApLedgerView) &&
        permissions.contains(Perm.financeViewAll);
  }

  bool get _canViewLossClaims => ref
      .read(currentPermissionsProvider)
      .contains(Perm.subcontractLossClaimView);

  bool get _canViewSupplierSettlements => ref
      .read(currentPermissionsProvider)
      .contains(Perm.supplierSettlementView);

  bool get _canApplyOffset {
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.supplierOpenItemOffsetApply) &&
        permissions.contains(Perm.financeViewAll);
  }

  List<FinancePayableItem> get _selectedItems {
    return [
      for (final id in _selectedIds)
        if (_selectedItemsById[id] != null) _selectedItemsById[id]!,
    ];
  }

  FinancePayableItem? get _selectedSingle =>
      _selectedItems.length == 1 ? _selectedItems.single : null;

  bool get _selectedOnlyPositivePayables =>
      _selectedItems.isNotEmpty &&
      _selectedItems.every((item) => item.openItemKind == 'PAYABLE');

  @override
  void initState() {
    super.initState();
    if (!_canViewPayables) {
      if (_canViewLossClaims) {
        _workspace = _PayablesWorkspaceView.lossClaims;
      } else if (_canViewSupplierSettlements) {
        _workspace = _PayablesWorkspaceView.supplierSettlements;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(financeNameServiceProvider).ensureLoaded();
      if (_workspace == _PayablesWorkspaceView.payables && _canViewPayables) {
        _load(1);
      }
    });
  }

  String? _fmt(DateTime? value) {
    if (value == null) return null;
    return '${value.year}-${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }

  Future<void> _load([int? requestedPage]) async {
    if (!_canViewPayables) return;
    final generation = _requests.begin();
    final page = requestedPage ?? _page;
    setState(() {
      _page = page;
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(financePayablesRepositoryProvider)
          .list(
            page: page,
            filter: FinancePayablesFilter(
              businessType: _businessType,
              supplierId: _supplierId,
              status: _status,
              settlementMethodId: _settlementMethodId,
              keyword: _keyword,
              dateFrom: _fmt(_dateFrom),
              dateTo: _fmt(_dateTo),
              dueFrom: _fmt(_dueFrom),
              dueTo: _fmt(_dueTo),
            ),
            sort: _sortKey,
            order: _sortKey == null ? null : (_sortAsc ? 'asc' : 'desc'),
          );
      if (!mounted || !_requests.isCurrent(generation)) return;
      setState(() {
        _result = result;
        _loading = false;
        for (final item in result.items) {
          if (_selectedIds.contains(item.id)) {
            _selectedItemsById[item.id] = item;
          }
        }
      });
    } on ApiException catch (error) {
      _setLoadError(generation, error.message);
    } catch (_) {
      _setLoadError(generation, '服务暂不可用，请稍后重试');
    }
  }

  void _setLoadError(int generation, String message) {
    if (!mounted || !_requests.isCurrent(generation)) return;
    setState(() {
      _loading = false;
      _error = message;
    });
    context.appError('加载应付结算失败：$message');
  }

  void _changeFilter(VoidCallback change) {
    setState(() {
      change();
      _selectedIds = <String>{};
      _selectedItemsById.clear();
    });
    _load(1);
  }

  int get _activeFilterCount {
    return <bool>[
      _keyword.trim().isNotEmpty,
      _businessType != null,
      _supplierId != null,
      _status != null,
      _settlementMethodId != null,
      _dateFrom != null || _dateTo != null,
      _dueFrom != null || _dueTo != null,
    ].where((active) => active).length;
  }

  void _resetFilters() {
    if (_activeFilterCount == 0) return;
    _changeFilter(() {
      _keyword = '';
      _businessType = null;
      _supplierId = null;
      _status = null;
      _settlementMethodId = null;
      _dateFrom = null;
      _dateTo = null;
      _dueFrom = null;
      _dueTo = null;
    });
  }

  void _setSelectedIds(Set<String> ids) {
    final current = _result?.items ?? const <FinancePayableItem>[];
    setState(() {
      _selectedIds = ids;
      _selectedItemsById.removeWhere((id, _) => !ids.contains(id));
      for (final item in current) {
        if (ids.contains(item.id)) _selectedItemsById[item.id] = item;
      }
    });
  }

  void _onColumnFilterChanged(String key, String? value) {
    _changeFilter(() {
      switch (key) {
        case 'businessType':
          _businessType = value;
          break;
        case 'supplierName':
          _supplierId = value;
          break;
        case 'settlementMethod':
          _settlementMethodId = value;
          break;
        case 'status':
          _status = value;
          break;
      }
    });
  }

  void _onSortChange(String? column, bool ascending) {
    setState(() {
      _sortKey = column;
      _sortAsc = ascending;
    });
    _load(1);
  }

  Future<DateTime?> _pickDate(DateTime? current) => showDatePicker(
    context: context,
    initialDate: current ?? DateTime.now(),
    firstDate: DateTime(2000),
    lastDate: DateTime(2100),
  );

  void _createPayment() {
    if (!_selectedOnlyPositivePayables) return;
    context.push(financePayablesPaymentLocation(_selectedIds));
  }

  Future<void> _applySelectedCredit() async {
    final source = _selectedSingle;
    if (source == null ||
        _applyingOffset ||
        (source.openItemKind != 'CREDIT' &&
            source.openItemKind != 'CLAIM_CREDIT')) {
      return;
    }
    final draft = await showSupplierCreditApplyPanel(
      context: context,
      source: source,
    );
    if (draft == null || !mounted) return;
    setState(() => _applyingOffset = true);
    try {
      final batchId = await ref
          .read(financePayablesRepositoryProvider)
          .applyOffset(
            sourceLedgerId: source.id,
            effectiveDate: draft.effectiveDate,
            reason: draft.reason,
            targets: draft.targets,
          );
      if (!mounted) return;
      setState(() {
        _applyingOffset = false;
        _selectedIds = <String>{};
        _selectedItemsById.clear();
      });
      context.appSuccess(
        batchId == null || batchId.isEmpty ? '贷项已应用' : '贷项已应用，批次 $batchId',
      );
      await _load(1);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _applyingOffset = false);
      context.appError(error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _applyingOffset = false);
      context.appError('贷项应用失败，请稍后重试');
    }
  }

  List<MasterColumnDef<FinancePayableItem>> get _columns => [
    MasterColumnDef(
      key: 'businessType',
      label: '业务类型',
      width: 90,
      value: (item) => item.businessTypeLabel,
    ),
    MasterColumnDef(
      key: 'sourceDocType',
      label: '来源类型',
      width: 120,
      value: (item) => item.sourceTypeLabel,
    ),
    MasterColumnDef(
      key: 'sourceDocNo',
      label: '来源单号',
      width: 160,
      value: (item) => item.sourceDocNo,
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '供应商/委外商',
      width: 210,
      value: (item) => [
        item.supplierCode,
        item.supplierName,
      ].whereType<String>().where((text) => text.isNotEmpty).join(' · '),
    ),
    MasterColumnDef(
      key: 'billDate',
      label: '立账日',
      width: 110,
      type: 'date',
      sortable: true,
      value: (item) => item.billDate,
    ),
    MasterColumnDef(
      key: 'dueDate',
      label: '到期日',
      width: 110,
      type: 'date',
      sortable: true,
      value: (item) => item.dueDate,
    ),
    MasterColumnDef(
      key: 'settlementMethod',
      label: '结算方式',
      width: 110,
      value: (item) => item.settlementMethodName,
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
      key: 'openItemKind',
      label: '余额类型',
      width: 120,
      value: (item) => item.openItemKindLabel,
    ),
    MasterColumnDef(
      key: 'grossOriginal',
      label: '应付(原币)',
      width: 120,
      type: 'money',
      value: (item) => item.grossOriginal,
    ),
    MasterColumnDef(
      key: 'grossLocal',
      label: '应付(本币)',
      width: 120,
      type: 'money',
      value: (item) => item.grossLocal,
    ),
    MasterColumnDef(
      key: 'paidOriginal',
      label: '现金已付(原币)',
      width: 120,
      type: 'money',
      value: (item) => item.paidOriginal,
    ),
    MasterColumnDef(
      key: 'paidLocal',
      label: '现金已付(本币)',
      width: 120,
      type: 'money',
      value: (item) => item.paidLocal,
    ),
    MasterColumnDef(
      key: 'offsetOriginal',
      label: '抵销(原币)',
      width: 120,
      type: 'money',
      value: (item) => item.offsetOriginal,
    ),
    MasterColumnDef(
      key: 'offsetLocal',
      label: '抵销(本币)',
      width: 120,
      type: 'money',
      value: (item) => item.offsetLocal,
    ),
    MasterColumnDef(
      key: 'outstandingOriginal',
      label: '未付(原币)',
      width: 120,
      type: 'money',
      sortable: true,
      value: (item) => item.outstandingOriginal,
    ),
    MasterColumnDef(
      key: 'outstandingLocal',
      label: '未付(本币)',
      width: 120,
      type: 'money',
      value: (item) => item.outstandingLocal,
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 100,
      value: (item) => item.statusLabel,
    ),
    MasterColumnDef(
      key: 'overdueDays',
      label: '逾期天数',
      width: 90,
      type: 'number',
      sortable: true,
      value: (item) => item.overdueDays?.toString(),
    ),
  ];

  String? get _selectionUnavailableReason {
    if (_selectedIds.isEmpty) return null;
    if (_selectedItems.length != _selectedIds.length) {
      return '部分选中记录已变化，请刷新后重试';
    }
    final single = _selectedSingle;
    if (single?.openItemKind == 'PREPAYMENT') {
      return '供应商预付款需走专用预付款资产/总账链';
    }
    if (_selectedOnlyPositivePayables) return null;
    if (single != null &&
        (single.openItemKind == 'CREDIT' ||
            single.openItemKind == 'CLAIM_CREDIT')) {
      return null;
    }
    return '不能混选正应付、贷项和预付款';
  }

  Widget _payablesTableToolbar({
    required ThemeData theme,
    required List<FinancePayableItem> pageItems,
    required int total,
    required bool canCreatePayment,
    required bool canApplyOffset,
  }) {
    final canSelect = canCreatePayment || canApplyOffset;
    final reason = _selectionUnavailableReason;
    final selectedPrepayment = _selectedSingle?.openItemKind == 'PREPAYMENT';
    final heading = Row(
      children: [
        Icon(
          Icons.payments_outlined,
          size: 20,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            '采购与委外应付',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s8,
            vertical: UtenSpacing.s4,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: UtenRadius.smAll,
          ),
          child: Text(
            '共 $total 笔',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
    final actions = Wrap(
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.end,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            '已选 ${_selectedIds.length} 项',
            style: theme.textTheme.labelLarge?.copyWith(
              color: _selectedIds.isEmpty
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.small,
          onPressed: pageItems.isEmpty
              ? null
              : () => _setSelectedIds({
                  ..._selectedIds,
                  for (final item in pageItems) item.id,
                }),
          child: const Text('全选本页'),
        ),
        UtenButton(
          type: UtenButtonType.ghost,
          size: UtenButtonSize.small,
          onPressed: _selectedIds.isEmpty
              ? null
              : () => _setSelectedIds(<String>{}),
          child: const Text('清空'),
        ),
        _payablesPrimaryAction(
          canCreatePayment: canCreatePayment,
          canApplyOffset: canApplyOffset,
        ),
      ],
    );
    final notice = selectedPrepayment
        ? '供应商预付款需专用预付款资产/总账链，当前不可自动核销或应用。'
        : reason;
    return Column(
      key: const ValueKey('finance-payables-table-toolbar'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s12,
            UtenSpacing.s8,
            UtenSpacing.s12,
            UtenSpacing.s8,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (!canSelect) return heading;
              if (constraints.maxWidth >= 760) {
                return Row(
                  children: [
                    Expanded(child: heading),
                    const SizedBox(width: UtenSpacing.s12),
                    actions,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  heading,
                  const SizedBox(height: UtenSpacing.s8),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              );
            },
          ),
        ),
        if (_selectedIds.isNotEmpty && notice != null)
          Semantics(
            liveRegion: true,
            label: notice,
            child: Container(
              key: const ValueKey('finance-payables-selection-notice'),
              margin: const EdgeInsets.fromLTRB(
                UtenSpacing.s12,
                0,
                UtenSpacing.s12,
                UtenSpacing.s8,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s12,
                vertical: UtenSpacing.s8,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                borderRadius: UtenRadius.smAll,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 18,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      notice,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _payablesPrimaryAction({
    required bool canCreatePayment,
    required bool canApplyOffset,
  }) {
    final selected = _selectedSingle;
    final selectedCredit =
        selected != null &&
        (selected.openItemKind == 'CREDIT' ||
            selected.openItemKind == 'CLAIM_CREDIT');
    final useCreditAction = canApplyOffset && selectedCredit;
    final usePaymentAction = !useCreditAction && canCreatePayment;
    final enabled = useCreditAction
        ? !_applyingOffset
        : usePaymentAction
        ? _selectedOnlyPositivePayables
        : false;
    final label = useCreditAction
        ? '应用贷项'
        : usePaymentAction
        ? (_selectedIds.isEmpty ? '生成付款单' : '生成付款单(${_selectedIds.length})')
        : '应用贷项';
    final disabledReason = _selectedIds.isEmpty
        ? (usePaymentAction ? '请先选择正应付记录' : '请先选择一笔贷项')
        : _selectionUnavailableReason ??
              (usePaymentAction ? '所选记录不能生成付款单' : '请选择一笔贷项');
    return Tooltip(
      message: enabled ? label : disabledReason,
      child: UtenButton(
        key: useCreditAction
            ? const ValueKey('finance-payables-apply-credit')
            : const ValueKey('finance-payables-create-payment'),
        size: UtenButtonSize.small,
        icon: useCreditAction ? Icons.link_rounded : Icons.add_card_rounded,
        isLoading: useCreditAction && _applyingOffset,
        onPressed: enabled
            ? (useCreditAction ? _applySelectedCredit : _createPayment)
            : null,
        onDisabledTap: enabled
            ? null
            : () => context.appWarning(disabledReason),
        child: Text(label),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(financeNameServiceProvider);
    final settlementMethods =
        ref.watch(settlementMethodOptionsProvider).valueOrNull ?? const [];
    final canCreatePayment = _canCreatePayment;
    final canApplyOffset = _canApplyOffset;
    final isExpanded = context.breakpoint.isExpanded;
    final availableWorkspaces = <_PayablesWorkspaceView>[
      if (_canViewPayables) _PayablesWorkspaceView.payables,
      if (_canViewLossClaims) _PayablesWorkspaceView.lossClaims,
      if (_canViewSupplierSettlements)
        _PayablesWorkspaceView.supplierSettlements,
    ];
    final total = _result?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '应付结算工作台',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.finance),
        ),
        actions: [
          if (_workspace == _PayablesWorkspaceView.payables && _canViewPayables)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: '刷新',
              onPressed: _loading ? null : () => _load(),
            ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
            child: Column(
              children: [
                if (availableWorkspaces.length > 1) ...[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SegmentedButton<_PayablesWorkspaceView>(
                      segments: [
                        if (_canViewPayables)
                          const ButtonSegment(
                            value: _PayablesWorkspaceView.payables,
                            icon: Icon(Icons.account_balance_wallet_outlined),
                            label: Text('应付台账'),
                          ),
                        if (_canViewLossClaims)
                          ButtonSegment(
                            value: _PayablesWorkspaceView.lossClaims,
                            icon: const Icon(Icons.gavel_outlined),
                            label: Text(
                              '委外超耗责任'
                              '${(_result?.summary.pendingLossCases ?? 0) > 0 ? ' (${_result!.summary.pendingLossCases})' : ''}',
                            ),
                          ),
                        if (_canViewSupplierSettlements)
                          const ButtonSegment(
                            value: _PayablesWorkspaceView.supplierSettlements,
                            icon: Icon(Icons.calendar_month_outlined),
                            label: Text('月结批次'),
                          ),
                      ],
                      selected: {_workspace},
                      onSelectionChanged: (selection) => setState(() {
                        _workspace = selection.single;
                        _selectedIds = <String>{};
                        _selectedItemsById.clear();
                      }),
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                ],
                if (_workspace == _PayablesWorkspaceView.payables &&
                    _canViewPayables)
                  Expanded(
                    child: UtenCollapsingHeaderScrollView(
                      collapsingHeader: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FinancePayablesKpiStrip(
                            summary: _result?.summary,
                            loading: _loading && _result == null,
                          ),
                          if (!isExpanded) ...[
                            const SizedBox(height: UtenSpacing.s12),
                            _compactFilterBar(theme),
                          ],
                          const SizedBox(height: UtenSpacing.s12),
                        ],
                      ),
                      body: isExpanded
                          ? UtenListTwoPane(
                              siderWidth: 280,
                              filterPane: _buildFilters(),
                              tablePane: _buildPayablesTablePane(
                                theme: theme,
                                names: names.supplierEntries,
                                settlementMethods: settlementMethods,
                                total: total,
                                canCreatePayment: canCreatePayment,
                                canApplyOffset: canApplyOffset,
                              ),
                            )
                          : _buildPayablesTablePane(
                              theme: theme,
                              names: names.supplierEntries,
                              settlementMethods: settlementMethods,
                              total: total,
                              canCreatePayment: canCreatePayment,
                              canApplyOffset: canApplyOffset,
                            ),
                    ),
                  )
                else if (_workspace == _PayablesWorkspaceView.lossClaims &&
                    _canViewLossClaims)
                  const Expanded(child: SubcontractLossClaimPanel())
                else if (_workspace ==
                        _PayablesWorkspaceView.supplierSettlements &&
                    _canViewSupplierSettlements)
                  const Expanded(child: SupplierSettlementPanel())
                else
                  const Expanded(
                    child: Center(child: Text('缺少应付、委外超耗责任或月结批次查看权限')),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPayablesTablePane({
    required ThemeData theme,
    required Map<String, String> names,
    required List<ReferenceMethodOption> settlementMethods,
    required int total,
    required bool canCreatePayment,
    required bool canApplyOffset,
  }) {
    final pageItems = _result?.items ?? const <FinancePayableItem>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _payablesTableToolbar(
          theme: theme,
          pageItems: pageItems,
          total: total,
          canCreatePayment: canCreatePayment,
          canApplyOffset: canApplyOffset,
        ),
        Expanded(
          child: MasterDataTableView<FinancePayableItem>(
            primary: true,
            columns: _columns,
            items: pageItems,
            facets: {
              'businessType': financePayablesBusinessTypeFacets,
              'supplierName': financeDictionaryFacets(names),
              'settlementMethod': financeDictionaryFacets({
                for (final method in settlementMethods)
                  method.id: '${method.name}(${method.code})',
              }),
              'status': financePayablesStatusFacets,
            },
            nullCounts: const {},
            filters: {
              'businessType': _businessType,
              'supplierName': _supplierId,
              'settlementMethod': _settlementMethodId,
              'status': _status,
            },
            onFilterChanged: _onColumnFilterChanged,
            sortColumn: _sortKey,
            sortAscending: _sortAsc,
            onSortChange: _onSortChange,
            selectable: canCreatePayment || canApplyOffset,
            idOf: (item) => item.id,
            selectedIds: _selectedIds,
            onSelectedIdsChanged: _setSelectedIds,
            isLoading: _loading && _result == null,
            loadingMore: _loading && _result != null,
            error: _error,
            onRetry: () => _load(),
            emptyMessage: '暂无符合条件的应付记录',
            currentPage: _result?.page ?? 1,
            totalPages: _result?.totalPages ?? 1,
            onPageChange: (page) => _load(page),
          ),
        ),
      ],
    );
  }

  Widget _compactFilterBar(ThemeData theme) {
    return Container(
      key: const ValueKey('finance-payables-compact-filter-bar'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Expanded(
            child: UtenSearchBar(
              key: const ValueKey('finance-payables-search'),
              hint: '搜索来源单号、供应商或委外商',
              initialValue: _keyword,
              onChanged: (value) => _changeFilter(() => _keyword = value),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          UtenButton(
            key: const ValueKey('finance-payables-open-filters'),
            type: UtenButtonType.secondary,
            size: UtenButtonSize.small,
            icon: Icons.tune_rounded,
            onPressed: _showCompactFilters,
            child: Text(
              _activeFilterCount == 0 ? '筛选' : '筛选($_activeFilterCount)',
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showCompactFilters() async {
    await showUtenAdaptivePanel<void>(
      context: context,
      showDragHandle: true,
      barrierLabel: '关闭应付筛选',
      builder: (panelContext) => StatefulBuilder(
        builder: (context, setPanelState) {
          void changeFilter(VoidCallback change) {
            _changeFilter(change);
            setPanelState(() {});
          }

          void resetFilters() {
            _resetFilters();
            setPanelState(() {});
          }

          final theme = Theme.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s16,
                  UtenSpacing.s8,
                  UtenSpacing.s8,
                  UtenSpacing.s8,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.filter_alt_outlined,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        '筛选应付记录',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (_activeFilterCount > 0)
                      Text(
                        '$_activeFilterCount 项生效',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(panelContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: theme.colorScheme.outlineVariant),
              Expanded(
                child: SingleChildScrollView(
                  primary: false,
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: _buildFilters(
                    showSearch: false,
                    changeFilter: changeFilter,
                    resetFilters: resetFilters,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilters({
    bool showSearch = true,
    void Function(VoidCallback change)? changeFilter,
    VoidCallback? resetFilters,
  }) {
    final applyFilter = changeFilter ?? _changeFilter;
    final applyReset = resetFilters ?? _resetFilters;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showSearch)
            UtenSearchBar(
              key: const ValueKey('finance-payables-search'),
              hint: '搜索来源单号、供应商或委外商',
              initialValue: _keyword,
              onChanged: (value) => applyFilter(() => _keyword = value),
            ),
          if (_activeFilterCount > 0) ...[
            const SizedBox(height: UtenSpacing.s4),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('finance-payables-reset-filters'),
                onPressed: _loading ? null : applyReset,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: Text('重置筛选 ($_activeFilterCount)'),
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          _filterLabel('业务类型'),
          Wrap(
            spacing: UtenSpacing.s4,
            runSpacing: UtenSpacing.s4,
            children: [
              _choice('全部', _businessType == null, () {
                applyFilter(() => _businessType = null);
              }),
              _choice('采购', _businessType == 'PURCHASE', () {
                applyFilter(() => _businessType = 'PURCHASE');
              }),
              _choice('委外', _businessType == 'SUBCONTRACT', () {
                applyFilter(() => _businessType = 'SUBCONTRACT');
              }),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          _filterLabel('结算状态'),
          Wrap(
            spacing: UtenSpacing.s4,
            runSpacing: UtenSpacing.s4,
            children: [
              _choice('全部', _status == null, () {
                applyFilter(() => _status = null);
              }),
              _choice('未付', _status == 'OPEN', () {
                applyFilter(() => _status = 'OPEN');
              }),
              _choice('部分', _status == 'PARTIAL', () {
                applyFilter(() => _status = 'PARTIAL');
              }),
              _choice('已结清', _status == 'SETTLED', () {
                applyFilter(() => _status = 'SETTLED');
              }),
              _choice('逾期', _status == 'OVERDUE', () {
                applyFilter(() => _status = 'OVERDUE');
              }),
              _choice('贷项', _status == 'CREDIT', () {
                applyFilter(() => _status = 'CREDIT');
              }),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          _dateRange(
            label: '立账日期',
            from: _dateFrom,
            to: _dateTo,
            onChanged: (from, to) => applyFilter(() {
              _dateFrom = from;
              _dateTo = to;
            }),
          ),
          const SizedBox(height: UtenSpacing.s12),
          _dateRange(
            label: '到期日期',
            from: _dueFrom,
            to: _dueTo,
            onChanged: (from, to) => applyFilter(() {
              _dueFrom = from;
              _dueTo = to;
            }),
          ),
        ],
      ),
    );
  }

  Widget _filterLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _choice(String label, bool selected, VoidCallback onSelected) =>
      ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onSelected(),
      );

  Widget _dateRange({
    required String label,
    required DateTime? from,
    required DateTime? to,
    required void Function(DateTime? from, DateTime? to) onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _filterLabel(label),
        Wrap(
          spacing: UtenSpacing.s4,
          runSpacing: UtenSpacing.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              onPressed: () async {
                final picked = await _pickDate(from);
                if (picked != null && mounted) onChanged(picked, to);
              },
              icon: const Icon(Icons.event_outlined, size: 18),
              label: Text(from == null ? '起始' : _fmt(from)!),
            ),
            TextButton.icon(
              onPressed: () async {
                final picked = await _pickDate(to);
                if (picked != null && mounted) onChanged(from, picked);
              },
              icon: const Icon(Icons.event_outlined, size: 18),
              label: Text(to == null ? '截止' : _fmt(to)!),
            ),
            if (from != null || to != null)
              IconButton(
                icon: const Icon(Icons.clear_rounded, size: 18),
                tooltip: '清除$label',
                onPressed: () => onChanged(null, null),
              ),
          ],
        ),
      ],
    );
  }
}
