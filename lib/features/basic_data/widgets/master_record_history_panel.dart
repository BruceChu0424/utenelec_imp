import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../shared/auth/permissions.dart';
import 'master_inline_edit.dart';

export 'master_record_revision_body.dart';

/// Opens the full history page and tracks restoration even on browser back.
Future<void> showMasterRecordHistory(
  BuildContext context, {
  required String entityType,
  String? recordId,
  String? categoryId,
  required VoidCallback onChanged,
}) async {
  final signal = ValueNotifier(false);
  try {
    await context.push<bool>(
      Uri(
        path: '/basicinfo/history',
        queryParameters: {
          'entityType': entityType,
          'recordId': ?recordId,
          'categoryId': ?categoryId,
        },
      ).toString(),
      extra: signal,
    );
  } finally {
    final changed = signal.value;
    signal.dispose();
    if (changed && context.mounted) onChanged();
  }
}

bool canReadMasterRecordHistory(String entityType, Set<String> permissions) {
  final permission = const {
    'goods': 'goods',
    'clients': 'client',
    'suppliers': 'supplier',
    'moulds': 'mould',
    'colors': 'color',
    'units': 'unit',
    'currencies': 'currency',
    'warehouses': 'warehouse',
    'accounts': 'account',
    'reference-methods': 'settlement_method',
    'payment-styles': 'payment_style',
  }[entityType];
  return permission != null && permissions.contains('$permission:view');
}

class MasterRecordHistoryAction extends ConsumerWidget {
  const MasterRecordHistoryAction({
    super.key,
    required this.entityType,
    this.recordId,
    this.categoryId,
    required this.onChanged,
    this.enabled = true,
  });
  final String entityType;
  final String? recordId;
  final String? categoryId;
  final VoidCallback onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(isSuperAdminProvider) &&
        !canReadMasterRecordHistory(
          entityType,
          ref.watch(currentPermissionsProvider),
        )) {
      return const SizedBox.shrink();
    }
    return UtenAppBarActionButton(
      label: masterEditText(context, '修改历史', 'Change history', '변경 기록'),
      onPressed: !enabled
          ? null
          : () async {
              if (!await confirmMasterInlineLeave(context) ||
                  !context.mounted) {
                return;
              }
              await showMasterRecordHistory(
                context,
                entityType: entityType,
                recordId: recordId,
                categoryId: categoryId,
                onChanged: onChanged,
              );
            },
    );
  }
}
