// 采购单据列表页（按 docType 参数化）。
//
// 复用基础资料布局：UtenAppBar(标题/返回/刷新) + UtenContentContainer > 标题行
// (Icon+label+(N)+搜索+新建) + 状态筛选(ChoiceChip Wrap) + MasterDataTableView。
// 过滤由本页自带的状态 ChoiceChip + 关键词搜索承担（facets 传空，表头降级为纯标签）。
// 名称解析（供应商/仓库）通过 MasterNameService。编辑按 edit 权限显隐「新建」。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_list_two_pane.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/widgets/doc_kpi_bar.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/purchase_repository.dart';

class PurchaseDocListPage extends ConsumerStatefulWidget {
  const PurchaseDocListPage({super.key, required this.docType});
  final PurchaseDocType docType;

  @override
  ConsumerState<PurchaseDocListPage> createState() => _PurchaseDocListPageState();
}

class _PurchaseDocListPageState extends ConsumerState<PurchaseDocListPage> {
  PurchaseDocConfig get _cfg => PurchaseDocConfig.by(widget.docType);
  PagedResult<PurchaseDocListItem>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  int? _statusFilter; // null=全部

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(masterNameServiceProvider).ensureLoaded();
      _load(1);
    });
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(_cfg.editPerm);

  Future<void> _load(int page) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref
          .read(purchaseRepositoryProvider(widget.docType))
          .list(
            page: page,
            filter: PurchaseDocFilter(
              keyword: _keyword.trim().isEmpty ? null : _keyword,
              status: _statusFilter,
            ),
          );
      if (!mounted) return;
      setState(() {
        _page = r;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载列表失败'; // TODO(l10n): 补 arb
        _loading = false;
      });
    }
  }

  void _onStatus(int? s) {
    setState(() => _statusFilter = s);
    _load(1);
  }

  List<MasterColumnDef<PurchaseDocListItem>> _columns(MasterNameService names) {
    return <MasterColumnDef<PurchaseDocListItem>>[
      MasterColumnDef(
          key: 'billNo', label: '单据号', width: 140, value: (it) => it.billNo),
      MasterColumnDef(
          key: 'billDate',
          label: '日期',
          width: 120,
          value: (it) => (it.billDate ?? '').substring(0, 10)),
      if (_cfg.hasSupplier)
        MasterColumnDef(
            key: 'supplier',
            label: '供应商',
            width: 200,
            value: (it) => names.supplier(it.supplierId)),
      MasterColumnDef(
          key: 'warehouse',
          label: '仓库',
          width: 160,
          value: (it) => names.warehouse(it.warehouseId)),
      MasterColumnDef(
          key: 'total',
          label: '合计',
          width: 140,
          value: (it) => it.totalLocal?.toStringAsFixed(2)),
      MasterColumnDef(
          key: 'status',
          label: '状态',
          width: 100,
          value: (it) => purchaseStatusLabel(it.status)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final total = _page?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: _cfg.label,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.purchase),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新', // TODO(l10n): 补 arb
            onPressed: () => _load(_pageNum),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                // 页面头：Icon + 标题 + 计数 + 新建按钮（搜索条挪到下方筛选区/侧栏）
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8,
                      left: UtenSpacing.s4,
                      right: UtenSpacing.s4),
                  child: Row(
                    children: [
                      Icon(_cfg.icon,
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: UtenSpacing.s8),
                      Text('${_cfg.shortLabel} ($total)',
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const Spacer(),
                      if (_canEdit)
                        UtenButton(
                          type: UtenButtonType.tonal,
                          icon: Icons.add_rounded,
                          onPressed: () => context.push(
                              RoutePath.purchaseDocNew(_cfg.type.pathSegment)),
                          child: const Text('新建'), // TODO(l10n): 补 arb
                        ),
                    ],
                  ),
                ),
                // KPI 条：状态过滤 + 概览（横向 4 卡，桌面常驻表格上方，全宽）
                Padding(
                  padding: const EdgeInsets.only(
                      bottom: UtenSpacing.s8, left: UtenSpacing.s4),
                  child: DocKpiBar(
                    counter: _countStatus,
                    selected: _statusFilter,
                    onSelect: _onStatus,
                  ),
                ),
                // 桌面：左筛选侧栏（搜索）+ 右表格；手机：垂直堆叠
                Expanded(
                  child: UtenListTwoPane(
                    filterPane: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: UtenSpacing.s4),
                      child: SizedBox(
                        width: double.infinity,
                        child: UtenSearchBar(
                          hint: '搜索单据号', // TODO(l10n): 补 arb
                          initialValue: _keyword,
                          onChanged: (v) {
                            setState(() => _keyword = v);
                            _load(1);
                          },
                        ),
                      ),
                    ),
                    tablePane: MasterDataTableView<PurchaseDocListItem>(
                      columns: _columns(names),
                      items: _page?.items ?? const [],
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      onRowTap: (it) => context.push(RoutePath.purchaseDocDetail(
                          _cfg.type.pathSegment, it.id)),
                      isLoading: _loading && _page == null,
                      loadingMore: _loading && _page != null,
                      error: _error,
                      onRetry: () => _load(_pageNum),
                      emptyMessage: '暂无${_cfg.shortLabel}单', // TODO(l10n): 补 arb
                      currentPage: _page?.page ?? 1,
                      totalPages: _page?.totalPages ?? 1,
                      onPageChange: (p) => _load(p),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 各状态单据数（KPI 条用，并行 4 次 list size=1 取 total）。
  Future<int> _countStatus(int? s) async {
    try {
      final r = await ref
          .read(purchaseRepositoryProvider(widget.docType))
          .list(page: 1, size: 1, filter: PurchaseDocFilter(status: s));
      return r.total;
    } catch (_) {
      return 0;
    }
  }
}
