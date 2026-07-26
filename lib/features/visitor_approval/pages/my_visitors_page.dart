// 我的访客(被访人)：确认/拒绝转给自己的访客申请。
//
// 响应式：compact 自套 UtenContentContainer 收敛；medium+ 外壳已收敛
//（移除页内重复的 1600 限宽），网格按容器宽度自适应列数。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../visitor/repositories/visitor_staff_repository.dart';
import '../../visitor/widgets/visitor_status_ui.dart';
import '../providers/visitor_approval_providers.dart';
import '../providers/visitor_pending_count_provider.dart';

class MyVisitorsPage extends ConsumerWidget {
  const MyVisitorsPage({super.key});

  Future<void> _confirm(WidgetRef ref, String id, bool confirmed, AppLocalizations l10n) async {
    try {
      await ref.read(visitorStaffRepositoryProvider).hostConfirm(id, confirmed: confirmed);
      ref.invalidate(myAsHostProvider);
      // 确认后回到 pending（HR 待办）或 rejected，两个徽章都要刷新
      ref.read(visitorHostPendingCountProvider.notifier).refresh();
      ref.read(visitorPendingCountProvider.notifier).refresh();
    } on ApiException catch (e) {
      ref.context.appApiError(e, fallback: l10n.commonError);
    } catch (_) {
      ref.context.appError(l10n.commonError);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final list = ref.watch(myAsHostProvider);
    return Scaffold(
      appBar: UtenAppBar(title: l10n.myVisitorsTitle, showBackButton: true),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(myAsHostProvider),
        child: list.when(
          loading: () => const UtenSkeletonList(itemCount: 4),
          error: (e, _) => UtenEmpty.error(
            message: '$e',
            actionLabel: l10n.commonRetry,
            onAction: () => ref.invalidate(myAsHostProvider),
          ),
          data: (items) {
            if (items.isEmpty) {
              return ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const SizedBox(height: 80),
                  UtenEmpty(icon: Icons.person_search_rounded, message: l10n.myVisitorsEmpty),
                ],
              );
            }
            final isCompact = context.breakpoint.isCompact;
            // 被访人待确认是个人 + 瞬态（status=hostReviewing，确认后即脱离），
            // 常态 0-3 条，无需分页。
            Widget grid = UtenResponsiveGrid(
              itemCount: items.length,
              itemBuilder: (context, i, itemWidth) {
                final app = items[i];
                return UtenCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(app.visitorName,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: UtenSpacing.s4),
                      Text('${l10n.visitorDetailPurpose}: ${app.visitPurpose}',
                          style: Theme.of(context).textTheme.bodyMedium),
                      const SizedBox(height: UtenSpacing.s4),
                      Text('${l10n.visitorDetailVisitTime}: ${fmtDateTime(app.plannedVisitAt)}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      const SizedBox(height: UtenSpacing.s12),
                      Row(
                        children: [
                          Expanded(
                            child: UtenButton(
                              type: UtenButtonType.danger,
                              onPressed: () => _confirm(ref, app.id, false, l10n),
                              child: Text(l10n.myVisitorsReject),
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s12),
                          Expanded(
                            child: UtenButton(
                              onPressed: () => _confirm(ref, app.id, true, l10n),
                              child: Text(l10n.myVisitorsConfirm),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            );
            if (isCompact) grid = UtenContentContainer(child: grid);
            return SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.symmetric(
                horizontal: isCompact ? 0 : UtenSpacing.s16,
                vertical: UtenSpacing.s16,
              ),
              child: grid,
            );
          },
        ),
      ),
    );
  }
}
