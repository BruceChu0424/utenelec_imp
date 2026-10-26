import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/layout/uten_app_bar_action_scope.dart';
import '../../../core/router/page_navigation_session.dart';
import '../../../shared/auth/permissions.dart';
import 'master_inline_edit.dart';

export 'master_record_revision_body.dart';

/// Opens the full history page and tracks restoration even on browser back.
Future<void> showMasterRecordHistory(
  BuildContext context, {
  required PageNavigationSession navigation,
  required String entityType,
  String? recordId,
  String? categoryId,
  required VoidCallback onChanged,
}) async {
  final ownerRoute = ModalRoute.of(context);
  final signal = ValueNotifier(false);
  try {
    await navigation.push<bool>(
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
    if (changed &&
        context.mounted &&
        (ownerRoute?.isActive ?? true) &&
        (ownerRoute?.isCurrent ?? true)) {
      onChanged();
    }
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

class MasterRecordHistoryAction extends ConsumerStatefulWidget {
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
  ConsumerState<MasterRecordHistoryAction> createState() =>
      _MasterRecordHistoryActionState();
}

class _MasterRecordHistoryActionState
    extends ConsumerState<MasterRecordHistoryAction> {
  final _navigation = PageNavigationSession();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigation.attach(context);
  }

  @override
  void dispose() {
    _navigation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(isSuperAdminProvider) &&
        !canReadMasterRecordHistory(
          widget.entityType,
          ref.watch(currentPermissionsProvider),
        )) {
      return const SizedBox.shrink();
    }
    final actionContext = UtenAppBarActionScope.actionContextOf(context);
    final navigation =
        UtenAppBarActionScope.navigationOf(context) ?? _navigation;
    final entityType = widget.entityType;
    final recordId = widget.recordId;
    final categoryId = widget.categoryId;
    final onChanged = widget.onChanged;
    return UtenAppBarActionScope.withCloseBeforeAction(
      context,
      child: UtenAppBarActionButton(
        label: masterEditText(context, '修改历史', 'Change history', '변경 기록'),
        onPressed: !widget.enabled
            ? null
            : () async {
                if (!await confirmMasterInlineLeave(actionContext) ||
                    !actionContext.mounted) {
                  return;
                }
                await showMasterRecordHistory(
                  actionContext,
                  navigation: navigation,
                  entityType: entityType,
                  recordId: recordId,
                  categoryId: categoryId,
                  onChanged: onChanged,
                );
              },
      ),
    );
  }
}
