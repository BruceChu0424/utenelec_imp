// 销售订单进度详情页（快递式全链路追踪）。
//
// 2026-08-19 起替代原「排产进度底表弹窗」：订单进度查询卡点订单、订货单详情页
// 「排产进度」按钮都进入本整页。页面自上而下三段：
//   ① 订单摘要卡（单号/开单/交货/制单员/单据状态/财务状态/结案中止徽标）；
//   ② 产品进度（复用 SalesPlanProgressPanel，财务确认前按 V300 口径隐藏，只给提示）；
//   ③ 履约进度（UtenProgressTimeline 快递式时间线：下单→销售审核→财务审核→
//      物料分析→物料准备-采购/委外订货→生产计划→生产→发货→结案，
//      每环带责任人与发生时间，最新进展在最上面高亮）。
// 三个数据源并行加载（detail / plan-progress / progress-timeline），互不阻塞。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/feedback/uten_progress_timeline.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/progress_timeline_event.dart';
import '../models/sales_doc.dart';
import '../repositories/sales_repository.dart';
import '../widgets/sales_plan_progress_panel.dart';

class SalesOrderProgressDetailPage extends ConsumerStatefulWidget {
  const SalesOrderProgressDetailPage({super.key, required this.orderId});

  final String orderId;

  @override
  ConsumerState<SalesOrderProgressDetailPage> createState() =>
      _SalesOrderProgressDetailPageState();
}

class _SalesOrderProgressDetailPageState
    extends ConsumerState<SalesOrderProgressDetailPage> {
  SalesDocDetail? _detail;
  List<ProgressTimelineEvent>? _timeline;
  String? _detailError;
  String? _timelineError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 摘要与时间线并行加载，各自独立展示错误，不互相阻塞。
  Future<void> _load() async {
    final repo = ref.read(salesRepositoryProvider(SalesDocType.order));
    repo
        .detail(widget.orderId)
        .then((d) {
          if (mounted) setState(() => _detail = d);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _detailError = '$e');
        });
    repo
        .progressTimeline(widget.orderId)
        .then((events) {
          if (mounted) setState(() => _timeline = events);
        })
        .catchError((Object e) {
          if (mounted) setState(() => _timelineError = '$e');
        });
  }

  Future<void> _reload() async {
    setState(() {
      _detail = null;
      _timeline = null;
      _detailError = null;
      _timelineError = null;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: UtenAppBar(
        title: '订单进度详情',
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: RouteName.salesOrderProgress),
        ),
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(UtenSpacing.s12),
              children: [
                _summarySection(),
                const SizedBox(height: UtenSpacing.s16),
                const UtenSectionHeader(title: '产品进度'),
                const SizedBox(height: UtenSpacing.s8),
                _productProgressSection(),
                const SizedBox(height: UtenSpacing.s16),
                const UtenSectionHeader(title: '履约进度'),
                const SizedBox(height: UtenSpacing.s8),
                _timelineSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================ ① 订单摘要 ============================

  Widget _summarySection() {
    final theme = Theme.of(context);
    if (_detailError != null) {
      return _errorCard(theme, '订单摘要加载失败：$_detailError');
    }
    final d = _detail;
    if (d == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(UtenSpacing.s24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    d.billNo ?? '—',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _docStatusChip(theme, d),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s16,
              runSpacing: UtenSpacing.s4,
              children: [
                if (d.billDate != null) _kv(theme, '开单日期', _date(d.billDate!)),
                if (d.deliverDate != null && d.deliverDate!.isNotEmpty)
                  _kv(theme, '交货日期', _date(d.deliverDate!)),
                if (d.makerName != null) _kv(theme, '制单员', d.makerName!),
              ],
            ),
            if (d.financeRejected) ...[
              const SizedBox(height: UtenSpacing.s12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(
                    alpha: 0.55,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.error.withValues(alpha: 0.35),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '驳回原因：${d.financeRejectedReason?.trim().isNotEmpty == true ? d.financeRejectedReason!.trim() : '未注明原因'}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if ((d.financeRejectedByName?.isNotEmpty ?? false) ||
                        (d.financeRejectedAt?.isNotEmpty ?? false)) ...[
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        [
                          if (d.financeRejectedByName?.isNotEmpty ?? false)
                            d.financeRejectedByName!,
                          if (d.financeRejectedAt?.isNotEmpty ?? false)
                            DisplayDateTime.beijing(
                              d.financeRejectedAt,
                              fallback: d.financeRejectedAt!,
                            ),
                        ].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ],
                    if (d.writable &&
                        (ref.read(isSuperAdminProvider) ||
                            ref
                                .read(currentPermissionsProvider)
                                .contains(Perm.salesOrderEdit))) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          onPressed: () => context.push(
                            RoutePath.salesDocEdit('orders', widget.orderId),
                          ),
                          icon: const Icon(Icons.edit_outlined),
                          label: const Text('修改订单'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s4,
              children: [
                _financeChip(theme, d),
                if (d.closed) _flagChip(theme, '已结案', Colors.green),
                if (d.stopped) _flagChip(theme, '已中止', theme.colorScheme.error),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _docStatusChip(ThemeData theme, SalesDocDetail d) {
    final (label, color) = switch (d.status) {
      1 => ('已审核', Colors.green),
      -1 => ('已红冲', theme.colorScheme.error),
      _ => ('草稿', theme.colorScheme.onSurfaceVariant),
    };
    return _flagChip(theme, label, color);
  }

  Widget _financeChip(ThemeData theme, SalesDocDetail d) {
    if (d.financeConfirmed) {
      return _flagChip(
        theme,
        '财务已确认${d.financeConfirmedByName != null ? ' · ${d.financeConfirmedByName}' : ''}',
        Colors.green,
      );
    }
    if (d.financeRejected) {
      return _flagChip(theme, '财务已驳回', theme.colorScheme.error);
    }
    return _flagChip(theme, '待财务确认', theme.colorScheme.tertiary);
  }

  Widget _flagChip(ThemeData theme, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _kv(ThemeData theme, String label, String value) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          TextSpan(
            text: value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ============================ ② 产品进度 ============================

  Widget _productProgressSection() {
    final theme = Theme.of(context);
    final d = _detail;
    // V300 口径：财务确认前不展示排产/链路进度，仅提示（时间线区仍可见审核轨迹）。
    if (d != null && d.financeRejected) {
      return Card(
        margin: EdgeInsets.zero,
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Row(
            children: [
              Icon(
                Icons.assignment_late_outlined,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '订单已被财务驳回。修改并重新审核提交财务前，不展示排产与产品进度。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (d != null && !d.financeConfirmed) {
      return Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Row(
            children: [
              Icon(
                Icons.hourglass_top_rounded,
                size: 20,
                color: theme.colorScheme.tertiary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '该订单等待财务审核，审核通过后显示排产与产品进度',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return SalesPlanProgressPanel(orderId: widget.orderId);
  }

  // ============================ ③ 履约进度（快递式时间线） ============================

  Widget _timelineSection() {
    final theme = Theme.of(context);
    if (_timelineError != null) {
      return _errorCard(theme, '履约进度加载失败：$_timelineError');
    }
    final events = _timeline;
    if (events == null) {
      return const Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.all(UtenSpacing.s24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: UtenProgressTimeline(
          events: events,
          onOpenDoc: _openLinkedDoc,
          emptyText: '暂无履约进度',
        ),
      ),
    );
  }

  /// 时间线单号跳转：按 docType 映射目标详情页；无权限时顶部提示。
  void _openLinkedDoc(ProgressTimelineEvent event) {
    if (!event.hasDoc) return;
    final perms = ref.read(currentPermissionsProvider);
    final superAdmin = ref.read(isSuperAdminProvider);
    bool can(String perm) => superAdmin || perms.contains(perm);
    final (path, perm) = switch (event.docType) {
      'SALES_SHIPMENT' => (
        '/sales/shipments/${event.docId}',
        Perm.salesShipmentView,
      ),
      'PURCHASE_ORDER' => (
        '/purchase/orders/${event.docId}',
        Perm.purchaseOrderView,
      ),
      'SUBCONTRACT_ORDER' => (
        '/subcontract/orders/${event.docId}',
        Perm.subcontractOrderView,
      ),
      'PRODUCTION_PLAN' => (
        RoutePath.productionPlanDetail(event.docId!),
        Perm.productionPlanView,
      ),
      'MATERIAL_ANALYSIS' => (
        RouteName.productionMaterialAnalysis,
        Perm.productionMaterialAnalysisView,
      ),
      _ => (null, null),
    };
    if (path == null || perm == null) return;
    if (!can(perm)) {
      context.appWarning('当前账号没有该单据的查看权限', force: true);
      return;
    }
    context.push(path);
  }

  Widget _errorCard(ThemeData theme, String message) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Text(message, style: TextStyle(color: theme.colorScheme.error)),
      ),
    );
  }

  String _date(String value) =>
      value.length >= 10 ? value.substring(0, 10) : value;
}
