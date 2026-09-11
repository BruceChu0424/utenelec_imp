// 销售管理入口页（hub）—— 两个分组卡片：
//  ① 销售管理：5 单据卡片（报价/订货/出货/其它出货/退货）
//  ② 销售报表：报表卡片（明细/汇总/待交货）
// 点卡片进对应列表/报表页。卡片按权限显隐（无 view 权限不渲染对应入口）；
// 销售管理卡 / 销售报表卡 若整组无可显项则整卡隐藏。
//
// 卡片统一用 UtenHubCard，右上角徽章槽恒放红色待办数（准则 14-徽章与计数口径）：
//   · 任务中心卡：SalesProgressBadge（财务驳回 + 完工提醒，TodoEntry.salesAttention）。
//   · 报价/订货/出货/退货单据卡：UtenDraftBadge（本人待自审草稿数）——2026-09-11 起
//     草稿由中性括号改红徽章并逐级累加（TodoEntry.salesDrafts）。
// 顶栏右上角另有一枚红徽章 = 本模块累计（全部登记入口之和）。
// 「客户零星发货」故意不显草稿数——与「销售出货」同属 sales_shipments，
// /sales/shipments 列表本就含这批单，两处各显一次会双计（见 todo_badge_registry 末注）。
// 权限来自 currentPermissionsProvider；路由用 SalesRoutePath 字面量。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/cards/uten_hub_card.dart';
import '../../../components/feedback/uten_draft_badge.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/todo_badge_registry.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../widgets/sales_progress_badge.dart';

class SalesHubPage extends ConsumerWidget {
  const SalesHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final perms = ref.watch(currentPermissionsProvider);

    // 任务中心：订单进度查询（财务驳回待修正 + 未读完工提醒同源徽章）。
    final taskEntries = <_Entry>[
      _Entry(
        icon: Icons.timeline_outlined,
        label: l10n.salesHubTaskOrderProgress,
        description: l10n.salesHubTaskOrderProgressSub,
        location: RouteName.salesOrderProgress,
        listPerm: Perm.salesOrderView,
        badge: const SalesProgressBadge(),
      ),
    ].where((e) => perms.contains(e.listPerm)).toList();

    final docEntries = <_Entry>[
      _Entry.fromCfg(SalesDocConfig.quote, l10n),
      _Entry.fromCfg(SalesDocConfig.order, l10n),
      _Entry.fromCfg(SalesDocConfig.shipment, l10n),
      _Entry.fromCfg(SalesDocConfig.customerShipment, l10n),
      _Entry.fromCfg(SalesDocConfig.otherShipment, l10n),
      _Entry.fromCfg(SalesDocConfig.returnDoc, l10n),
    ].where((e) => perms.contains(e.listPerm)).toList();

    final reportEntries = <_Entry>[
      _Entry(
        icon: Icons.list_alt_outlined,
        label: l10n.salesHubReportDetail,
        description: l10n.hubSubDetailPerItem,
        location: SalesRoutePath.reportDetail,
        listPerm: SalesPerm.reportView,
      ),
      _Entry(
        icon: Icons.bar_chart_outlined,
        label: l10n.salesHubReportSummary,
        description: l10n.hubSubSummaryPerDoc,
        location: SalesRoutePath.reportSummary,
        listPerm: SalesPerm.reportView,
      ),
    ].where((e) => perms.contains(e.listPerm)).toList();

    // 稀缺仲裁：主管查看货品预留占用、释放低优先级现货预留（让单）。仅持让单权限者可见。
    final scarcityEntries = <_Entry>[
      _Entry(
        icon: Icons.swap_horizontal_circle_outlined,
        label: l10n.salesHubScarcity,
        description: l10n.salesHubScarcitySub,
        location: RouteName.salesScarcity,
        listPerm: Perm.salesOrderReallocate,
      ),
    ].where((e) => perms.contains(e.listPerm)).toList();

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.salesHubTitle,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          // 本模块累计：数字由 todo_badge_registry 对 TodoModule.sales 下全部登记入口
          // 求和得出（已含各单据卡草稿），**页面里不要手写加法**——新增入口只改注册表。
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: Center(
              child: UtenNotificationBadge(
                count: todoModuleCount(TodoModule.sales, ref.watch),
                size: 20,
                showLabel: true,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          // 轮询页不包选择区：销售进度徽章定时刷新（结构性闪现）与拖选并发有
          // CME 风险（准则 §3.4，用户口径：轮询页不包）。
          selectable: false,
          child: ListView(
            padding: EdgeInsets.only(
              top: UtenSpacing.s12,
              // 外壳 compact 已预留胶囊高度；medium+/桌面 Rail 不预留，取更大值。
              bottom: context.breakpoint.isCompact
                  ? UtenSpacing.s16
                  : UtenSpacing.s40,
            ),
            children: [
              if (taskEntries.isNotEmpty)
                _section(
                  context,
                  theme,
                  l10n.hubSectionTaskCenter,
                  taskEntries,
                ),
              if (taskEntries.isNotEmpty)
                const SizedBox(height: UtenSpacing.s16),
              if (docEntries.isNotEmpty)
                _section(context, theme, l10n.salesHubTitle, docEntries),
              if (docEntries.isNotEmpty && reportEntries.isNotEmpty)
                const SizedBox(height: UtenSpacing.s16),
              if (reportEntries.isNotEmpty)
                _section(
                  context,
                  theme,
                  l10n.salesHubSectionReports,
                  reportEntries,
                ),
              if (reportEntries.isNotEmpty && scarcityEntries.isNotEmpty)
                const SizedBox(height: UtenSpacing.s16),
              if (scarcityEntries.isNotEmpty)
                _section(
                  context,
                  theme,
                  l10n.salesHubSectionScarcity,
                  scarcityEntries,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一个分组：标题 + 卡片网格。
  Widget _section(
    BuildContext context,
    ThemeData theme,
    String title,
    List<_Entry> entries,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: UtenSpacing.s4,
              bottom: UtenSpacing.s8,
            ),
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          UtenResponsiveGrid(
            itemCount: entries.length,
            spacing: UtenSpacing.s12,
            columns: const UtenResponsiveColumns(compact: 2, medium: 4),
            itemBuilder: (context, i, _) => _EntryTile(entry: entries[i]),
          ),
        ],
      ),
    );
  }
}

/// 一个入口项（单据类型或报表）。
class _Entry {
  _Entry({
    required this.icon,
    required this.label,
    required this.description,
    required this.location,
    required this.listPerm,
    this.badge,
  });

  /// 单据卡；有草稿计数口径的类型挂草稿红徽章（本人待自审草稿数）。
  ///
  /// 草稿占的是 [badge]（卡片右上角浮层）而不是标题右侧的 labelSuffix：销售这几张
  /// 单据卡本身没有别的待办徽章，右上角空着——用户要的就是这个位置。只有像采购收货
  /// 那样已被「待收货」占掉 badge 的卡，草稿才退到标题行内（一个槽塞两个红点读不懂）。
  _Entry.fromCfg(SalesDocConfig cfg, AppLocalizations l10n)
    : icon = cfg.icon,
      label = _salesDocTitle(cfg.type, l10n),
      description = _salesDocSubtitle(cfg.type, l10n),
      location = cfg.skipListOnCreate
          ? SalesRoutePath.docNew(cfg.type.pathSegment)
          : SalesRoutePath.list(cfg.type.pathSegment),
      listPerm = cfg.listPerm,
      badge = cfg.draftKind == null
          ? null
          : UtenDraftBadge(kind: cfg.draftKind!);

  final IconData icon;
  final String label;
  final String description;
  final String location;
  final String listPerm;

  /// 右上角红色徽章（订单进度关注数 / 单据草稿数；null=无）。只放「需要我处理」的数。
  final Widget? badge;
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});
  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    return UtenHubCard(
      icon: entry.icon,
      label: entry.label,
      description: entry.description,
      onTap: () => goFrom(context, entry.location),
      badge: entry.badge,
    );
  }
}

// 单据卡标题/副标题本地化：config 仍是中文 const（列表/编辑页在用），
// hub 卡片经此映射按当前 locale 取标题 + 精简副标题。
String _salesDocTitle(SalesDocType t, AppLocalizations l10n) => switch (t) {
  SalesDocType.quote => l10n.salesHubDocQuote,
  SalesDocType.order => l10n.salesHubDocOrder,
  SalesDocType.shipment => l10n.salesHubDocShipment,
  SalesDocType.customerShipment => '客户零星发货',
  SalesDocType.otherShipment => l10n.salesHubDocOtherShipment,
  SalesDocType.returnDoc => l10n.salesHubDocReturn,
};

String _salesDocSubtitle(SalesDocType t, AppLocalizations l10n) => switch (t) {
  SalesDocType.quote => l10n.salesHubDocQuoteSub,
  SalesDocType.order => l10n.salesHubDocOrderSub,
  SalesDocType.shipment => l10n.salesHubDocShipmentSub,
  SalesDocType.customerShipment => '样品、赠送及没有订货单的客户发货，统一财审后出库',
  SalesDocType.otherShipment => l10n.salesHubDocOtherShipmentSub,
  SalesDocType.returnDoc => l10n.salesHubDocReturnSub,
};
