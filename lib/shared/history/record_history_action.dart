import '../../core/l10n/localized_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_app_bar_action_button.dart';
import '../../components/layout/uten_app_bar_action_scope.dart';
import '../../core/router/page_navigation_session.dart';
import '../../shared/auth/permissions.dart';
import '../../features/basic_data/widgets/master_inline_edit.dart';

import 'record_history_area.dart';
export 'record_revision_body.dart';

/// Opens the full history page and tracks restoration even on browser back.
Future<void> showMasterRecordHistory(
  BuildContext context, {
  required PageNavigationSession navigation,
  RecordHistoryArea area = RecordHistoryArea.master,
  String? entityType,
  String? recordId,
  String? categoryId,
  required VoidCallback onChanged,
}) async {
  final ownerRoute = ModalRoute.of(context);
  final signal = ValueNotifier(false);
  try {
    await navigation.push<bool>(
      Uri(
        path: area.routePath,
        queryParameters: {
          'entityType': ?entityType,
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
  final permission = RecordHistoryArea.master.viewPermissions[entityType];
  return permission != null && permissions.contains(permission);
}

class RecordHistoryAction extends ConsumerStatefulWidget {
  const RecordHistoryAction({
    super.key,
    this.area = RecordHistoryArea.master,
    this.entityType,
    this.recordId,
    this.categoryId,
    this.onChanged,
    this.enabled = true,
  });
  final RecordHistoryArea area;
  final String? entityType;
  final String? recordId;
  final String? categoryId;
  final VoidCallback? onChanged;
  final bool enabled;

  @override
  ConsumerState<RecordHistoryAction> createState() =>
      _MasterRecordHistoryActionState();
}

class _MasterRecordHistoryActionState
    extends ConsumerState<RecordHistoryAction> {
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
    final admin = ref.watch(isSuperAdminProvider);
    final grants = ref.watch(currentPermissionsProvider);
    if (!widget.area.canRead(admin, grants) ||
        (widget.entityType != null &&
            !admin &&
            !grants.contains(widget.area.viewPermissions[widget.entityType]))) {
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
        label: localizedText(context, '修改历史', 'Change history', '변경 기록'),
        onPressed: !widget.enabled
            ? null
            : () async {
                if ((widget.area == RecordHistoryArea.master &&
                        !await confirmMasterInlineLeave(actionContext)) ||
                    !actionContext.mounted) {
                  return;
                }
                await showMasterRecordHistory(
                  actionContext,
                  navigation: navigation,
                  area: widget.area,
                  entityType: entityType,
                  recordId: recordId,
                  categoryId: categoryId,
                  onChanged: onChanged ?? () {},
                );
              },
      ),
    );
  }
}

// Stable compatibility name for existing master-data consumers.
typedef MasterRecordHistoryAction = RecordHistoryAction;
