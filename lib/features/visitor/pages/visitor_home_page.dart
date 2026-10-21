// 访客首页：我的预约列表(按状态筛选)+ 新建预约入口。
//
// 2026-09-09 表格化改版：卡片网格 → MasterDataTableView（列对齐 + 分页）。
// 列：姓名/事由/接待人/计划到访/状态（原卡片字段全部保留，公司并入接待人
// 留空的回退展示）。访客端多为手机（375px 级窄屏）：表格窄屏横向滚动，
// 列宽自适应不溢出；无多选；行双击进预约详情。
//
// 响应式：访客流程不经主外壳，全断点自套 UtenContentContainer 收敛
//（列表页 maxWidth 1600，宽屏居中不拉宽，水平 gutter 由容器提供）。
import '../../../shared/models/retained_async_page.dart';
import '../../../shared/models/paged_result.dart';
import 'package:flutter/material.dart';

import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_app_bar_action_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/visitor_application.dart';
import '../providers/visitor_providers.dart';
import '../providers/visitor_session_provider.dart';
import '../widgets/visitor_status_ui.dart';
import '../../../components/data_display/uten_status_cell_color.dart';

// 在办仅含申请中和已批准待来访；签到、拒绝和取消均进入历史单据。
enum VisitorFilter { pending, approved, history }

class VisitorHomePage extends ConsumerStatefulWidget {
  const VisitorHomePage({super.key});

  @override
  ConsumerState<VisitorHomePage> createState() => _VisitorHomePageState();
}

class _VisitorHomePageState extends ConsumerState<VisitorHomePage> {
  bool _loggingOut = false;
  VisitorFilter _filter = VisitorFilter.pending;
  int _page = 1;
  final _retainedPage = RetainedAsyncPage<PagedResult<VisitorApplication>>();

  String? get _status => switch (_filter) {
    VisitorFilter.pending => 'pending,hostReviewing',
    VisitorFilter.approved => 'approved',
    VisitorFilter.history => 'checkedIn,rejected,cancelled',
  };

  VisitorApplicationsQuery get _query => (status: _status, page: _page);

  Future<void> _logout() async {
    if (_loggingOut) return;
    setState(() => _loggingOut = true);
    try {
      await ref.read(visitorSessionProvider.notifier).logout();
      if (mounted) context.go(RouteName.entry);
    } catch (_) {
      if (mounted) context.appError('退出失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _loggingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final visitor = ref.watch(visitorSessionProvider).visitor;
    final paginationScope = (_filter, visitor?.id);
    final apps = _retainedPage.resolve(
      paginationScope,
      ref.watch(visitorApplicationsProvider(_query)),
    );

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
          UtenAppBarActionButton(
            icon: Icons.logout_rounded,
            label: l10n.visitorLogout,
            tooltip: l10n.visitorLogout,
            isLoading: _loggingOut,
            onPressed: _loggingOut ? null : _logout,
          ),
        ],
      ),
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: UtenFloatingActionGroup(
        children: [
          UtenButton(
            size: UtenButtonSize.large,
            onPressed: () => context.go(RouteName.visitorApply),
            icon: Icons.add_rounded,
            child: Text(l10n.visitorApplyNew),
          ),
        ],
      ),
      // 全断点收敛：水平 gutter 由容器提供，页面自身水平 padding 让位
      body: UtenContentContainer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
              child: UtenFilterToolbar<VisitorFilter>(
                segmentsKey: const Key('visitor-home-segments'),
                autoSelectBadge: false,
                selected: {_filter},
                onSelectionChanged: (v) => setState(() {
                  _filter = v;
                  _page = 1;
                }),
                segments: [
                  UtenFilterSegment(
                    value: VisitorFilter.pending,
                    label: l10n.visitorFilterPending,
                  ),
                  UtenFilterSegment(
                    value: VisitorFilter.approved,
                    label: l10n.visitorFilterApproved,
                  ),
                  const UtenFilterSegment(
                    value: VisitorFilter.history,
                    label: '历史单据',
                  ),
                ],
              ),
            ),
            Expanded(
              child: apps.when(
                skipLoadingOnReload: true,
                skipError: true,
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
                    tableKey:
                        'features.visitor.pages.visitor_home_page.VisitorHomePageState.build.1',
                    bottomContentPadding:
                        UtenFloatingActionGroup.scrollClearance,
                    key: const Key('visitor-home-table'),
                    paginationScope: paginationScope,
                    loadingMore: apps.isLoading,
                    error: apps.hasError ? '${apps.error}' : null,
                    onRetry: () =>
                        ref.invalidate(visitorApplicationsProvider(_query)),
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
                    onPageChange: (p) async {
                      setState(() => _page = p);
                      await _retainedPage.waitFor(
                        ref,
                        visitorApplicationsProvider(_query),
                        () => ref.read(
                          visitorApplicationsProvider(_query).future,
                        ),
                      );
                    },
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
    key: 'status',
    label: l10n.visitorColStatus,
    width: 72,
    value: (app) => visitorStatusLabel(app.status, l10n),
    // 2026-09-27 用户口径「表格状态列整格底色」：与详情页徽章同源分类色。
    cellColor: (context, app) =>
        utenStatusBadgeCellColor(visitorBadgeType(app.status)),
  ),
  MasterColumnDef(
    key: 'visitorName',
    label: l10n.visitorColName,
    width: 110,
    value: (app) => app.visitorName,
  ),
  MasterColumnDef(
    key: 'visitPurpose',
    label: l10n.visitorColPurpose,
    width: 200,
    value: (app) => app.visitPurpose,
  ),
  MasterColumnDef(
    key: 'hostName',
    label: l10n.visitorColHost,
    width: 110,
    // 接待人缺省时回退公司名（原卡片口径），两者皆空留白。
    value: (app) => (app.hostName != null && app.hostName!.isNotEmpty)
        ? app.hostName
        : app.company,
  ),
  MasterColumnDef(
    key: 'plannedVisitAt',
    label: l10n.visitorColPlannedVisit,
    width: 150,
    type: 'date',
    value: (app) => fmtDateTime(app.plannedVisitAt),
  ),
];
