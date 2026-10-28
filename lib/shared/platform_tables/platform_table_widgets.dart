import 'package:flutter/material.dart';
import '../../components/data_display/uten_table_read_status.dart';
import '../../core/l10n/platform_table_recovery_text.dart';
import 'platform_table_controller.dart';
import 'platform_table_models.dart';
import 'platform_table_picker.dart';

/// One cell interaction for every platform table, including fullscreen views.
class PlatformColumnValue<T> extends StatelessWidget {
  const PlatformColumnValue({
    super.key,
    required this.controller,
    required this.row,
    required this.column,
  });
  final PlatformTableController<T> controller;
  final T row;
  final PlatformColumnDefinition column;
  @override
  Widget build(BuildContext context) {
    final signals = <Listenable>[
      ...?controller.binding?.factListenablesOf?.call(row),
      ...?controller.fallbackFactListenablesOf?.call(row),
      ?controller.draftOf?.call(row),
    ];
    if (column.calculated && signals.isNotEmpty) {
      return ListenableBuilder(
        listenable: Listenable.merge(signals),
        builder: (context, _) => _buildValue(context),
      );
    }
    return _buildValue(context);
  }

  Widget _buildValue(BuildContext context) {
    final value = controller.value(row, column);
    final needsAvailability =
        value == null && (controller.loading || controller.error != null);
    final draft = needsAvailability ? controller.draftOf?.call(row) : null;
    final awaitingRead =
        needsAvailability &&
        !controller.historical &&
        controller.capabilities?.supportsValues != false &&
        controller.binding?.recordIdOf(row)?.isNotEmpty == true &&
        (controller.rowValues(row) == null ||
            (draft != null &&
                !draft.loaded &&
                controller.cell(row, column.id) == null));
    if (awaitingRead) {
      // An unread value is not an empty business value or a formula failure.
      // Do not build extra draft snapshots on successful table reads.
      // Keep valid snapshots, staged cells and permission masks unchanged.
      return Tooltip(
        message: platformTableRecoveryText(context, 'cellHelp'),
        child: Text(
          platformTableRecoveryText(
            context,
            controller.loading ? 'cellLoading' : 'cellUnavailable',
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final editable = controller.canEdit(row, column);
    final text = Text(
      value?.isNotEmpty == true ? value! : '—',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.left,
    );
    final error =
        controller.cell(row, column.id)?.error ??
        (column.calculated &&
                value == null &&
                !(controller.historical &&
                    controller.capabilities?.supportsValues != false &&
                    controller.cell(row, column.id) == null)
            ? '所需数值为空、不可见，或计算不能得到精确有限小数'
            : null);
    if (error != null) {
      return Tooltip(
        message: error,
        child: Text(
          '计算不可用',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    if (!editable) return text;
    return Semantics(
      button: true,
      label: '编辑${column.name}',
      child: InkWell(
        onTap: () => showPlatformCellEditor(context, controller, row, column),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(child: text),
              const SizedBox(width: 6),
              const Icon(Icons.edit_outlined, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

/// Read-only recovery shared by every display and editable platform table.
class PlatformTableStatus extends StatelessWidget {
  const PlatformTableStatus({
    super.key,
    required this.error,
    required this.retry,
    this.loading = false,
    this.failure,
    this.ownerIdentity,
  });
  final String? error;
  final VoidCallback retry;
  final bool loading;
  final PlatformTableReadFailure? failure;
  final Object? ownerIdentity;

  @override
  Widget build(BuildContext context) {
    if (error == null) return const SizedBox.shrink();
    return UtenTableReadStatus(
      keyPrefix: 'platform-table-read',
      ownerIdentity: ownerIdentity,
      title: platformTableRecoveryText(context, 'title'),
      loadingTitle: platformTableRecoveryText(context, 'loading'),
      reason: platformTableRecoveryReason(context, error!),
      guidance: platformTableRecoveryText(
        context,
        failure?.name ?? 'unavailable',
      ),
      impact: platformTableRecoveryText(context, 'impact'),
      detailsLabel: platformTableRecoveryText(context, 'details'),
      retryLabel: platformTableRecoveryText(context, 'retry'),
      closeLabel: platformTableRecoveryText(context, 'close'),
      retry: retry,
      loading: loading,
    );
  }
}
