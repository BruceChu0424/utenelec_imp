import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_hub_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../components/feedback/uten_in_progress_badge.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';

class MyApplicationsPage extends ConsumerWidget {
  const MyApplicationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    int fact(String key) => ref.watch<int>(badgeFactProvider(key));
    final permissions = ref.watch(currentPermissionsProvider);
    final superAdmin = ref.watch(isSuperAdminProvider);
    bool canOpen(String location) =>
        locationAllowedFor(permissions, superAdmin, location);
    final entries = <({String label, IconData icon, String location})>[
      (
        label: '申请报销',
        icon: Icons.receipt_long_outlined,
        location: '/expense/new?kind=GENERAL',
      ),
      (
        label: '申请出差报销',
        icon: Icons.luggage_outlined,
        location: '/expense/new?kind=TRAVEL',
      ),
      (
        label: '申请出差',
        icon: Icons.business_center_outlined,
        location: '/applications/new?kind=TRAVEL',
      ),
      (
        label: '申请付款',
        icon: Icons.payments_outlined,
        location: '/applications/new?kind=PAYMENT',
      ),
      (
        label: '申请预付',
        icon: Icons.account_balance_wallet_outlined,
        location: '/applications/new?kind=PREPAYMENT',
      ),
      (
        label: '供应商付款申请',
        icon: Icons.storefront_outlined,
        location: '/applications/new?kind=SUPPLIER_PAYMENT',
      ),
    ].where((entry) => canOpen(entry.location)).toList();
    // 2026-11-04 我的申请改版：报销不再单独设「我的报销」卡，报销记录并入
    // 「申请记录」页分类栏的「报销申请」段（红黄徽章随段迁移）。
    final records = <({String label, IconData icon, String location})>[
      if (canOpen('/applications/mine'))
        (
          label: '申请记录',
          icon: Icons.folder_open_outlined,
          location: '/applications/mine',
        ),
    ];
    Widget grid(
      List<({String label, IconData icon, String location})> values,
    ) => UtenResponsiveGrid(
      itemCount: values.length,
      columns: const UtenResponsiveColumns(compact: 2, medium: 3),
      spacing: UtenSpacing.s12,
      itemBuilder: (context, index, width) {
        final entry = values[index];
        final records = entry.location == '/applications/mine';
        final int todo = records
            ? ref.watch(badgeEntryTodoProvider(BadgeEntry.applicationMine))
            : 0;
        final processing = records
            ? fact('application.mineProcessingCount')
            : 0;
        return UtenHubCard(
          key: ValueKey(entry.location),
          icon: entry.icon,
          label: entry.label,
          onTap: () => goFrom(context, entry.location),
          badge: todo > 0 ? UtenNotificationBadge(count: todo) : null,
          progressBadge: processing > 0
              ? UtenInProgressBadge(count: processing)
              : null,
        );
      },
    );
    return Scaffold(
      appBar: const UtenAppBar(title: '我的申请', showBackButton: true),
      body: UtenContentContainer(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          children: [
            if (entries.isNotEmpty) ...[
              Text('新建申请', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: UtenSpacing.s12),
              grid(entries),
              const SizedBox(height: UtenSpacing.s24),
            ],
            if (records.isNotEmpty) ...[
              Text('我的记录', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: UtenSpacing.s12),
              grid(records),
            ],
          ],
        ),
      ),
    );
  }
}
