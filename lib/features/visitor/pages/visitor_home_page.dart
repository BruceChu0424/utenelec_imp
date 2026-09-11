// 访客首页：我的预约列表(按状态筛选)+ 新建预约入口。
//
// 2026-09-09 表格化改版：卡片网格 → MasterDataTableView（列对齐 + 分页）。
// 列：姓名/事由/接待人/计划到访/状态（原卡片字段全部保留，公司并入接待人
// 留空的回退展示）。访客端多为手机（375px 级窄屏）：表格窄屏横向滚动，
// 列宽自适应不溢出；无多选；行双击进预约详情。
//
// 响应式：访客流程不经主外壳，全断点自套 UtenContentContainer 收敛
//（列表页 maxWidth 1600，宽屏居中不拉宽，水平 gutter 由容器提供）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/visitor_application.dart';
import '../providers/visitor_providers.dart';
import '../providers/visitor_session_provider.dart';
import '../widgets/visitor_status_ui.dart';

enum VisitorFilter { all, pending, approved, rejected }

class VisitorHomePage extends ConsumerStatefulWidget {
  const VisitorHomePage({super.key});

  @override
  ConsumerState<VisitorHomePage> createState() => _VisitorHomePageState();
}

class _VisitorHomePageState extends ConsumerState<VisitorHomePage> {
  VisitorFilter _filter = VisitorFilter.all;
  int _page = 1;

  String? get _status => switch (_filter) {
    VisitorFilter.all => null,
    VisitorFilter.pending => 'pending',
    VisitorFilter.approved => 'approved',
    VisitorFilter.rejected => 'rejected',
  };

  VisitorApplicationsQuery get _query => (status: _status, page: _page);

  Future<void> _logout() async {
    await ref.read(visitorSessionProvider.notifier).logout();
    if (mounted) context.go(RouteName.entry);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final visitor = ref.watch(visitorSessionProvider).visitor;
    final apps = ref.watch(visitorApplicationsProvider(_query));

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.visitorHomeTitle,
        subtitle: visitor?.visitorNo,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: l10n.visitorSettingsTooltip,
            onPressed: () => context.go(RouteName.visitorSettings),
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded),
            tooltip: l10n.visitorLogout,
            onPressed: _logout,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go(RouteName.visitorApply),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.visitorApplyNew),
      ),
      // 全断点收敛：水平 gutter 由容器提供，页面自身水平 padding 让位
      body: UtenContentContainer(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(
                top: UtenSpacing.s12,
                bottom: UtenSpacing.s8,
              ),
              child: UtenSegmentedFilter<VisitorFilter>(
                selected: _filter,
                onChanged: (v) => setState(() {
                  _filter = v;
                  _page = 1;
                }),
                segments: [
                  UtenSegment(
                    value: VisitorFilter.all,
                    label: l10n.visitorFilterAll,
                  ),
                  UtenSegment(
                    value: VisitorFilter.pending,
                    label: l10n.visitorFilterPending,
                  ),
                  UtenSegment(
                    value: VisitorFilter.approved,
                    label: l10n.visitorFilterApproved,
                  ),
                  UtenSegment(
                    value: VisitorFilter.rejected,
                    label: l10n.visitorFilterRejected,
                  ),
                ],
              ),
            ),
            Expanded(
              child: apps.when(
                loading: () => const UtenSkeletonList(itemCount: 6),
                error: (e, _) => UtenEmpty.error(
                  message: '$e',
                  actionLabel: l10n.commonRetry,
                  onAction: () =>
                      ref.invalidate(visitorApplicationsProvider(_query)),
                ),
                data: (page) => RefreshIndicator(
                  onRefresh: () async =>
                      ref.invalidate(visitorApplicationsProvider(_query)),
                  child: MasterDataTableView<VisitorApplication>(
                    key: const Key('visitor-home-table'),
                    columns: _columns(l10n),
                    items: page.items,
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    // 双击行进入预约详情（保留现有路由与 go 语义）。
                    onRowTap: (app) => context.go('/visitor/apply/${app.id}'),
                    emptyMessage: l10n.commonNoData,
                    // 个人视角（仅当前访客自己的预约），天然几十以内，仍保留
                    // 后端分页的翻页条（页多时可用）。
                    currentPage: page.page,
                    totalPages: page.totalPages,
                    onPageChange: (p) => setState(() => _page = p),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<MasterColumnDef<VisitorApplication>> _columns(AppLocalizations l10n) => [
  MasterColumnDef(
    key: 'visitorName',
    label: '姓名',
    width: 110,
    value: (app) => app.visitorName,
  ),
  MasterColumnDef(
    key: 'visitPurpose',
    label: '事由',
    width: 200,
    value: (app) => app.visitPurpose,
  ),
  MasterColumnDef(
    key: 'hostName',
    label: '接待人',
    width: 110,
    // 接待人缺省时回退公司名（原卡片口径），两者皆空留白。
    value: (app) => (app.hostName != null && app.hostName!.isNotEmpty)
        ? app.hostName
        : app.company,
  ),
  MasterColumnDef(
    key: 'plannedVisitAt',
    label: '计划到访',
    width: 150,
    type: 'date',
    value: (app) => fmtDateTime(app.plannedVisitAt),
  ),
  MasterColumnDef(
    key: 'status',
    label: '状态',
    width: 90,
    value: (app) => visitorStatusLabel(app.status, l10n),
  ),
];
