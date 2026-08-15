// 生产链路健康初筛（当前只覆盖四类已结构化关系）。
//
// 扫描 销售订货 → 物料分析 → 生产计划 → 领料单/采购申请 四类断链：
//  ① 有销售缺口无分析  ② 有分析未排完计划  ③ 有计划未生成领料单  ④ 有领料单无计划来源
// 每类显示全量命中数 + 截断明细，点明细跳到权威单据修复。
// 数据全部来自服务端只读扫描（GET /production/chain-health），页面不自行推断。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_client.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/production_material_analysis.dart';

class ProductionChainHealthPage extends ConsumerStatefulWidget {
  const ProductionChainHealthPage({super.key});

  @override
  ConsumerState<ProductionChainHealthPage> createState() =>
      _ProductionChainHealthPageState();
}

class _ProductionChainHealthPageState
    extends ConsumerState<ProductionChainHealthPage> {
  List<ChainHealthCategoryView>? _categories;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ref
          .read(apiClientProvider)
          .getList('/production/chain-health', query: {'limit': 50});
      if (!mounted) return;
      setState(() {
        _categories = [
          for (final entry in list) ChainHealthCategoryView.fromJson(entry),
        ];
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: UtenAppBar(
        title: '链路健康初筛',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.production),
        ),
        actions: [
          IconButton(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            tooltip: '重新扫描',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: _loading && _categories == null
              ? const Center(child: CircularProgressIndicator())
              : _error != null && _categories == null
              ? _errorState()
              : _body(),
        ),
      ),
    );
  }

  Widget _errorState() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('扫描失败：$_error', textAlign: TextAlign.center),
        const SizedBox(height: UtenSpacing.s12),
        FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重试'),
        ),
      ],
    ),
  );

  Widget _body() {
    final categories = _categories ?? const [];
    final total = categories.fold<int>(0, (sum, c) => sum + c.count);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
      children: [
        _coverageNotice(),
        const SizedBox(height: UtenSpacing.s12),
        _summaryBanner(total),
        const SizedBox(height: UtenSpacing.s12),
        for (final category in categories) ...[
          _categoryCard(category),
          const SizedBox(height: UtenSpacing.s12),
        ],
      ],
    );
  }

  Widget _coverageNotice() {
    final theme = Theme.of(context);
    return Container(
      key: const Key('chain-health-coverage-notice'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: const Text(
        '当前扫描只覆盖：销售缺口、物料分析、生产计划和 DRAW 领料关系。'
        '采购/委外订单与 IQC、精确供给分配、报工、成品入库和发运仍需在各权威单据中核对；'
        '“0 项”只表示本次覆盖范围内未发现问题。',
      ),
    );
  }

  Widget _summaryBanner(int total) {
    final theme = Theme.of(context);
    final healthy = total == 0;
    final color = healthy ? theme.colorScheme.primary : theme.colorScheme.error;
    return Container(
      key: const Key('chain-health-summary'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(
            healthy ? Icons.verified_outlined : Icons.link_off_rounded,
            color: color,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              healthy ? '本次覆盖范围内未发现断链' : '发现 $total 处断链/待处理环节，逐条点击可跳到权威单据修复',
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _categoryCard(ChainHealthCategoryView category) {
    final theme = Theme.of(context);
    final hasIssues = category.count > 0;
    final color = hasIssues
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    return Card(
      key: Key('chain-health-${category.category}'),
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.mdAll,
        side: BorderSide(
          color: hasIssues
              ? color.withValues(alpha: 0.35)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  hasIssues
                      ? Icons.warning_amber_rounded
                      : Icons.check_circle_outline_rounded,
                  size: 20,
                  color: color,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    category.label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: UtenRadius.smAll,
                  ),
                  child: Text(
                    '${category.count}',
                    style: TextStyle(color: color, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              category.description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            if (category.issues.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s8),
              for (final issue in category.issues) _issueRow(theme, issue),
              if (category.count > category.issues.length)
                Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s4),
                  child: Text(
                    '仅显示前 ${category.issues.length} 条，共 ${category.count} 条',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _issueRow(ThemeData theme, ChainHealthIssueView issue) {
    return ListTile(
      key: ValueKey('chain-health-issue-${issue.route}-${issue.refId}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(_routeIcon(issue.route), size: 20),
      title: Text(
        {if (issue.billNo != null) issue.billNo!, issue.label}.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: issue.detail == null
          ? null
          : Text(issue.detail!, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => _open(issue),
    );
  }

  IconData _routeIcon(String route) => switch (route) {
    'SALES_ORDER' => Icons.receipt_long_outlined,
    'MATERIAL_ANALYSIS' => Icons.insights_outlined,
    'PRODUCTION_PLAN' => Icons.assignment_outlined,
    'STOCK_DRAW' => Icons.outbound_outlined,
    _ => Icons.link_rounded,
  };

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
