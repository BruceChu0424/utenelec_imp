import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../core/ui/human_error_message.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_material_analysis.dart';

/// Server-owned issue counts and bounded scan details, shown in the shared
/// table. A category count is not the number of records returned for that type.
class ProductionChainHealthPage extends ConsumerStatefulWidget {
  const ProductionChainHealthPage({super.key});

  @override
  ConsumerState<ProductionChainHealthPage> createState() =>
      _ProductionChainHealthPageState();
}

class _ProductionChainHealthPageState
    extends ConsumerState<ProductionChainHealthPage> {
  static const _detailLimit = 50;
  static const _allCategory = '__all__';
  List<ChainHealthCategoryView>? _categories;
  List<_ChainHealthRow> _rows = const [];
  String? _selectedCategory;
  bool _loading = false;
  String? _error;

  /// Existing return-to-page registration and request deduplication stay local.
  String? _myLocation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ref
          .read(apiClientProvider)
          .getList('/production/chain-health', query: {'limit': _detailLimit});
      if (!mounted) return;
      final categories = [
        for (final entry in list) ChainHealthCategoryView.fromJson(entry),
      ];
      final rows = <_ChainHealthRow>[];
      final occurrences = <String, int>{};
      for (final category in categories.where(
        (category) => category.count > 0,
      )) {
        for (final issue in category.issues) {
          final identity = '${category.category}:${issue.route}:${issue.refId}';
          final occurrence = occurrences.update(
            identity,
            (value) => value + 1,
            ifAbsent: () => 0,
          );
          rows.add(_ChainHealthRow(category, issue, '$identity:$occurrence'));
        }
      }
      setState(() {
        _categories = categories;
        _rows = rows;
        if (!categories.any(
          (category) =>
              category.count > 0 && category.category == _selectedCategory,
        )) {
          _selectedCategory = null;
        }
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = humanErrorMessage(error) ?? '链路健康数据没有加载出来，请重新扫描或重试。';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    _myLocation ??= currentLocationOr(context, RouteName.production);
    ref.onPageResume(_myLocation!, _load);
    return Scaffold(
      appBar: UtenAppBar(
        title: '链路健康初筛',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.production),
        ),
        actions: [
          UtenRefreshButton(
            tooltip: '重新扫描',
            enabled: !_loading,
            busy: _loading,
            onRefresh: _load,
          ),
        ],
      ),
      body: SafeArea(child: UtenContentContainer.wide(child: _body())),
    );
  }

  Widget _body() {
    final categories = (_categories ?? const <ChainHealthCategoryView>[])
        .where((category) => category.count > 0)
        .toList(growable: false);
    final selected = categories
        .where(
          (category) =>
              _selectedCategory == null ||
              category.category == _selectedCategory,
        )
        .toList(growable: false);
    final rows = _selectedCategory == null
        ? _rows
        : _rows
              .where((row) => row.category.category == _selectedCategory)
              .toList(growable: false);
    final total = selected.fold<int>(
      0,
      (sum, category) => sum + category.count,
    );
    final truncated = selected.any(
      (category) => category.count > category.issues.length,
    );
    final summary = _categories == null
        ? (_loading ? '正在扫描…' : '尚未获得扫描结果')
        : '${_loading ? '上次扫描：' : ''}待处理 $total 条 · 已展示 ${rows.length} 条'
              '${truncated ? '（明细已截断，每类最多 $_detailLimit 条）' : ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
          child: UtenFilterToolbar<String>(
            segmentsKey: const Key('chain-health-category-filter'),
            autoSelectBadge: false,
            segments: [
              const UtenFilterSegment(value: _allCategory, label: '全部'),
              for (final category in categories)
                UtenFilterSegment(
                  value: category.category,
                  label: category.label,
                  count: category.count,
                ),
            ],
            selected: {_selectedCategory ?? _allCategory},
            onSelectionChanged: (value) => setState(
              () => _selectedCategory = value == _allCategory ? null : value,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Semantics(
                    key: truncated
                        ? const Key('chain-health-truncation')
                        : null,
                    liveRegion: truncated,
                    child: Text(summary, key: const Key('chain-health-counts')),
                  ),
                ),
                _coverageNotice(),
              ],
            ),
          ),
        ),
        Expanded(
          child: MasterDataTableView<_ChainHealthRow>(
      expensiveRowMounts: false,
            key: const Key('chain-health-table'),
            tableKey:
                'features.production.pages.production_chain_health_page.ProductionChainHealthPage.issues',
            virtualized: true,
            rowKeyOf: (row) => row.key,
            items: rows,
            columns: [
              MasterColumnDef(
                key: 'category',
                label: '问题类型',
                width: 220,
                value: (row) => row.category.label,
                cellBuilder: (_, row) => Row(
                  children: [
                    Flexible(
                      child: Text(
                        row.category.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    UtenFieldHintIcon(
                      info:
                          '${row.category.label}\n\n${row.category.description}',
                      dense: true,
                    ),
                  ],
                ),
              ),
              MasterColumnDef(
                key: 'billNo',
                label: '单据编号',
                width: 160,
                value: (row) => row.issue.billNo ?? '—',
              ),
              MasterColumnDef(
                key: 'label',
                label: '事项',
                width: 260,
                value: (row) => row.issue.label,
                cellBuilder: (_, row) => Row(
                  children: [
                    Flexible(
                      child: Text(
                        row.repeatsBillNo || row.issue.label.isEmpty
                            ? '—'
                            : row.issue.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    UtenFieldHintIcon(
                      info: row.issue.label.isEmpty
                          ? null
                          : '原始事项：${row.issue.label}',
                      dense: true,
                    ),
                  ],
                ),
              ),
              MasterColumnDef(
                key: 'detail',
                label: '详情',
                width: 440,
                value: (row) => row.issue.detail ?? '—',
              ),
              MasterColumnDef(
                key: 'refId',
                label: '来源标识',
                width: 220,
                defaultVisible: false,
                value: (row) => row.issue.refId,
              ),
            ],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            onRowTap: (row) => _open(row.issue),
            isLoading: _loading && _categories == null,
            loadingMore: _loading && _categories != null,
            error: _error,
            onRetry: _load,
            emptyMessage: _categories == null
                ? '尚未获得扫描结果'
                : total > 0
                ? '本次扫描未返回本范围明细，请重新扫描或核对原单据'
                : '本次覆盖范围内暂无待处理问题',
            bottomContentPadding:
                UtenSpacing.s16 + UtenCapsuleNavScope.occlusionOf(context),
          ),
        ),
      ],
    );
  }

  Widget _coverageNotice() => const UtenFieldHintIcon(
    key: Key('chain-health-coverage-notice'),
    dense: true,
    info:
        '当前扫描覆盖：销售缺口、物料分析、生产计划与 DRAW、活动关系重复、'
        'fqty/iqty 事实对账、数量越界、执行段完成条件，以及 FQC 决定/入库授权守恒。'
        '采购/委外订单与 IQC 明细、精确供给分配和发运仍需在各权威单据中核对；'
        '“0 项”只表示本次覆盖范围内未发现问题。\n\n'
        '单击定位，双击进入原始单据。扫描明细按每类最多50条请求，'
        '计数为服务端全量命中数，不等于当前已展示条数。',
  );

  /// 跳到权威单据/工作台修复：订单行→订单详情；分析→恢复该分析；
  /// 计划→计划详情；领料单→仓库单据详情。
  void _open(ChainHealthIssueView issue) {
    switch (issue.route) {
      case 'SALES_ORDER':
        context.push(
          RoutePath.salesDocDetail('orders', issue.targetId ?? issue.refId),
        );
      case 'MATERIAL_ANALYSIS':
        context.push(
          RouteName.productionMaterialAnalysis,
          extra: ProductionMaterialAnalysisSeed(analysisId: issue.refId),
        );
      case 'PRODUCTION_PLAN':
        context.push(RoutePath.productionPlanDetail(issue.refId));
      case 'STOCK_DRAW':
        context.push(RoutePath.stockDocDetail('DRAW', issue.refId));
    }
  }
}

class _ChainHealthRow {
  const _ChainHealthRow(this.category, this.issue, this.key);
  final ChainHealthCategoryView category;
  final ChainHealthIssueView issue;
  final String key;

  bool get repeatsBillNo =>
      issue.billNo?.trim().isNotEmpty == true &&
      issue.billNo!.trim() == issue.label.trim();
}

class ChainHealthCategoryView {
  const ChainHealthCategoryView({
    required this.category,
    required this.label,
    required this.description,
    required this.count,
    required this.issues,
  });

  final String category;
  final String label;
  final String description;
  final int count;
  final List<ChainHealthIssueView> issues;

  factory ChainHealthCategoryView.fromJson(Map<String, dynamic> json) =>
      ChainHealthCategoryView(
        category: (json['category'] ?? '') as String,
        label: (json['label'] ?? '') as String,
        description: (json['description'] ?? '') as String,
        count: (json['count'] as num? ?? 0).toInt(),
        issues: [
          for (final entry in (json['issues'] as List? ?? const []))
            ChainHealthIssueView.fromJson(entry as Map<String, dynamic>),
        ],
      );
}

class ChainHealthIssueView {
  const ChainHealthIssueView({
    required this.refId,
    this.targetId,
    this.billNo,
    required this.label,
    this.detail,
    required this.route,
  });

  final String refId;
  final String? targetId;
  final String? billNo;
  final String label;
  final String? detail;
  final String route;

  factory ChainHealthIssueView.fromJson(Map<String, dynamic> json) =>
      ChainHealthIssueView(
        refId: json['refId'] as String,
        targetId: json['targetId'] as String?,
        billNo: json['billNo'] as String?,
        label: (json['label'] ?? '') as String,
        detail: json['detail'] as String?,
        route: (json['route'] ?? '') as String,
      );
}
