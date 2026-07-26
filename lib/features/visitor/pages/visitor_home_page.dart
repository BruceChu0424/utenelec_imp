// 访客首页：我的预约列表(按状态筛选)+ 新建预约入口。
//
// 响应式：访客流程不经主外壳，全断点自套 UtenContentContainer 收敛
//（列表页 maxWidth 1600，宽屏居中不拉宽，水平 gutter 由容器提供）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
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

  String? get _status => switch (_filter) {
        VisitorFilter.all => null,
        VisitorFilter.pending => 'pending',
        VisitorFilter.approved => 'approved',
        VisitorFilter.rejected => 'rejected',
      };

  Future<void> _logout() async {
    await ref.read(visitorSessionProvider.notifier).logout();
    if (mounted) context.go(RouteName.entry);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final visitor = ref.watch(visitorSessionProvider).visitor;
    final apps = ref.watch(visitorApplicationsProvider(_status));

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
                  top: UtenSpacing.s12, bottom: UtenSpacing.s8),
              child: UtenSegmentedFilter<VisitorFilter>(
                selected: _filter,
                onChanged: (v) => setState(() => _filter = v),
                segments: [
                  UtenSegment(value: VisitorFilter.all, label: l10n.visitorFilterAll),
                  UtenSegment(value: VisitorFilter.pending, label: l10n.visitorFilterPending),
                  UtenSegment(value: VisitorFilter.approved, label: l10n.visitorFilterApproved),
                  UtenSegment(value: VisitorFilter.rejected, label: l10n.visitorFilterRejected),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async => ref.invalidate(visitorApplicationsProvider(_status)),
                child: apps.when(
                  loading: () => const UtenSkeletonList(itemCount: 6),
                  error: (e, _) => UtenEmpty.error(
                    message: '$e',
                    actionLabel: l10n.commonRetry,
                    onAction: () => ref.invalidate(visitorApplicationsProvider(_status)),
                  ),
                  data: (list) {
                    if (list.isEmpty) {
                      return ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          const SizedBox(height: 80),
                          UtenEmpty(
                            icon: Icons.event_available_outlined,
                            message: l10n.commonNoData,
                            description: l10n.visitorApplyNew,
                          ),
                        ],
                      );
                    }
                    return SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                          vertical: UtenSpacing.s16),
                      // 个人视角（仅当前访客自己的预约），天然几十以内，无需分页。
                      child: UtenResponsiveGrid(
                        itemCount: list.length,
                        itemBuilder: (context, i, _) => _VisitorAppCard(
                          app: list[i],
                          onTap: () => context.go('/visitor/apply/${list[i].id}'),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VisitorAppCard extends StatelessWidget {
  const _VisitorAppCard({required this.app, required this.onTap});
  final VisitorApplication app;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return UtenCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: visitorStatusColor(app.status).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(visitorStatusIcon(app.status),
                    color: visitorStatusColor(app.status), size: 20),
              ),
              UtenStatusBadge(
                label: visitorStatusLabel(app.status, l10n),
                type: visitorBadgeType(app.status),
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(app.visitPurpose,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            app.hostName != null
                ? '${l10n.visitorDetailHost}: ${app.hostName}'
                : app.company ?? '',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(fmtDateTime(app.plannedVisitAt),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
