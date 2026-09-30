import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/inputs/uten_search_bar.dart';
import '../../../../components/layout/uten_adaptive_panel.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/network/latest_request_guard.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../../../basic_data/widgets/master_server_column_filters.dart';
import '../models/subcontract_loss_claim.dart';
import '../repositories/subcontract_loss_claim_repository.dart';
import 'subcontract_loss_claim_detail_panel.dart';

class SubcontractLossClaimPanel extends ConsumerStatefulWidget {
  const SubcontractLossClaimPanel({super.key, this.refreshTick = 0});

  /// 宿主（应付工作台）「返回即刷新」驱动的重载信号；数值变化时重拉当前页。
  final int refreshTick;

  @override
  ConsumerState<SubcontractLossClaimPanel> createState() =>
      _SubcontractLossClaimPanelState();
}

class _SubcontractLossClaimPanelState
    extends ConsumerState<SubcontractLossClaimPanel> {
  final _requests = LatestRequestGuard();
  SubcontractLossClaimPageResult? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  String? _status;
  int _page = 1;

  /// 表头排序 + 损耗单号列值筛选 + facets 桶 + 防串台代数
  /// （2026-09-25 单号列统一，共享状态见 MasterServerColumnFilters）；
  /// 排序列 key 见 [_kSortFields]，null = 服务端默认序。
  final _columnFilters = MasterServerColumnFilters();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  @override
  void didUpdateWidget(SubcontractLossClaimPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTick != oldWidget.refreshTick) {
      _load(_page);
    }
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
          .read(subcontractLossClaimRepositoryProvider)
          .list(
            status: _status,
            keyword: _keyword,
            page: page,
            sort: _kSortFields[_columnFilters.sortColumn],
            order: _columnFilters.sortColumn == null
                ? null
                : (_columnFilters.sortAscending ? 'asc' : 'desc'),
            wasteBillNo: _columnFilters['wasteBillNo'],
          );
      if (!mounted || !_requests.isCurrent(generation)) return;
      // 单号 facets 与列表同口径（2026-09-25 单号列统一）；失败静默（下拉降级为空）。
      unawaited(_loadWasteBillNoFacets());
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

  /// 表头排序键 → 服务端 sort 参数（2026-09-25 单号列统一；未列出的列不可排序）。
  static const _kSortFields = <String, String>{'wasteBillNo': 'wasteBillNo'};

  /// 表头排序变化：服务端重排整个结果集，回第 1 页。
  void _onSortChange(String? column, bool ascending) {
    final next = column != null && _kSortFields.containsKey(column)
        ? column
        : null;
    if (next == _columnFilters.sortColumn &&
        (next == null || ascending == _columnFilters.sortAscending)) {
      return;
    }
    _columnFilters.handleSortChanged(
      next,
      ascending,
      onChanged: () {
        if (mounted) setState(() {});
        _load(1);
      },
    );
  }

  /// 损耗单号 facets（2026-09-25 单号列统一）：与列表同过滤口径
  /// （不含单号列自身值筛选）。
  Future<void> _loadWasteBillNoFacets() => _columnFilters.loadFacets(
    () async => {
      'wasteBillNo': await ref
          .read(subcontractLossClaimRepositoryProvider)
          .wasteBillNoFacets(status: _status, keyword: _keyword),
    },
    onLoaded: () {
      if (mounted) setState(() {});
    },
  );

  void _fail(int generation, String message) {
    if (!mounted || !_requests.isCurrent(generation)) return;
    setState(() {
      _loading = false;
      _error = message;
    });
    context.appError('加载委外超耗责任失败：$message');
  }

  void _changeFilter(VoidCallback change) {
    setState(change);
    _load(1);
  }

  Future<void> _open(SubcontractLossClaimSummary item) async {
    await showUtenAdaptivePanel<void>(
      context: context,
      drawerWidth: 900,
      compactHeightFactor: 0.94,
      panelElevation: 12,
      builder: (_) => SubcontractLossClaimDetailPanel(
        caseId: item.id,
        onChanged: () => _load(),
      ),
    );
    // 详情面板内每个写动作成功都经 onChanged 重拉过；纯查看关闭不再多拉一次
    // （原来这里无条件 _load，一次定责=两次列表请求，纯查看关闭也多一次）。
  }

  List<MasterColumnDef<SubcontractLossClaimSummary>> _columns({
    required bool canViewFinancialAmounts,
  }) => [
    MasterColumnDef(
      key: 'wasteBillNo',
      label: '损耗单号',
      width: 160,
      sortable: true, // 2026-09-25 单号列统一：表头排序 + 值筛选。
      value: (item) => item.wasteBillNo,
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '委外商',
      width: 210,
      value: (item) => [
        item.supplierCode,
        item.supplierName,
      ].whereType<String>().where((value) => value.isNotEmpty).join(' · '),
    ),
    MasterColumnDef(
      key: 'actualLossQty',
      label: '实际损耗',
      width: 110,
      type: 'number',
      value: (item) => item.actualLossQty,
    ),
    MasterColumnDef(
      key: 'allowedLossQty',
      label: '允许损耗',
      width: 110,
      type: 'number',
      value: (item) => item.allowedLossQty,
    ),
    MasterColumnDef(
      key: 'excessLossQty',
      label: '超耗',
      width: 110,
      type: 'number',
      value: (item) => item.excessLossQty,
    ),
    if (canViewFinancialAmounts) ...[
      MasterColumnDef(
        key: 'lossBookValueLocal',
        label: '账面损失(本币)',
        width: 150,
        type: 'money',
        value: (item) => item.lossBookValueLocal,
      ),
      MasterColumnDef(
        key: 'claimAmountLocal',
        label: '索赔额(本币)',
        width: 140,
        type: 'money',
        value: (item) => item.claimAmountLocal,
      ),
    ],
    MasterColumnDef(
      key: 'status',
      label: '责任状态',
      width: 130,
      value: (item) => item.statusLabel,
    ),
    MasterColumnDef(
      key: 'createdAt',
      label: '生成时间',
      width: 170,
      value: (item) => item.createdAt,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _result?.total ?? 0;
    final canViewFinancialAmounts = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.financeViewAll);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Row(
            children: [
              Icon(
                Icons.gavel_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '委外超耗责任 ($total)',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              UtenButton(
                type: UtenButtonType.ghost,
                icon: Icons.refresh_rounded,
                onPressed: _loading ? null : () => _load(1),
                child: const Text('刷新'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UtenSearchBar(
                key: const ValueKey('subcontract-loss-claim-search'),
                hint: '搜索损耗单号、委外商编号或名称',
                initialValue: _keyword,
                onChanged: (value) => _changeFilter(() => _keyword = value),
              ),
              const SizedBox(height: UtenSpacing.s8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _statusChip('全部', null),
                    _statusChip('待处理', 'OPEN'),
                    _statusChip('争议中', 'DISPUTED'),
                    _statusChip('待履约', 'AWAITING_FULFILLMENT'),
                    _statusChip('已解决', 'RESOLVED'),
                    _statusChip('已反转', 'REVERSED'),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: MasterDataTableView<SubcontractLossClaimSummary>(
            tableKey:
                'features.finance.payables.widgets.subcontract_loss_claim_panel.SubcontractLossClaimPanelState.build.1',
            primary: true,
            columns: _columns(canViewFinancialAmounts: canViewFinancialAmounts),
            items: _result?.items ?? const [],
            // 损耗单号表头值筛选（2026-09-25 单号列统一）：服务端分组计数桶。
            facets: {'wasteBillNo': _columnFilters.bucketOf('wasteBillNo')},
            nullCounts: const {},
            filters: {'wasteBillNo': _columnFilters['wasteBillNo']},
            // 表头排序走服务端（2026-09-25 单号列统一）。
            sortColumn: _columnFilters.sortColumn,
            sortAscending: _columnFilters.sortAscending,
            onSortChange: _onSortChange,
            onFilterChanged: (key, value) {
              if (key == 'wasteBillNo') {
                _columnFilters.handleFilterChanged(
                  key,
                  value,
                  onChanged: () {
                    if (mounted) setState(() {});
                    _load(1);
                  },
                );
              }
            },
            onRowTap: _open,
            isLoading: _loading && _result == null,
            loadingMore: _loading && _result != null,
            error: _error,
            onRetry: () => _load(),
            emptyMessage: '暂无符合条件的委外超耗责任单',
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
      onSelected: (_) => _changeFilter(() => _status = value),
    ),
  );
}
