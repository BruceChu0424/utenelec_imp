import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/constants/app_info.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';

/// Release notes travel with the installed client, never with the latest server.
class AppVersionTile extends StatelessWidget {
  const AppVersionTile({super.key, this.version = AppInfo.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      leading: const Icon(Icons.info_outline, size: 20),
      title: Text(l10n.settingsVersion),
      subtitle: Text(l10n.releaseNotesOpen),
      trailing: Text(version),
      contentPadding: EdgeInsets.zero,
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => _ReleaseNotesDialog(version: version),
      ),
    );
  }
}

class _ReleaseNotesDialog extends StatelessWidget {
  const _ReleaseNotesDialog({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final normalized = version.startsWith('v') ? version.substring(1) : version;
    final notes = switch (normalized) {
      '2.5.3' => [
        l10n.release253Hr,
        l10n.release253Permissions,
        l10n.release253Materials,
        l10n.release253Ai,
        l10n.release253Notices,
        l10n.release253Reset,
        l10n.release253Maintenance,
      ],
      // v2.5.7 与 v2.5.6 同批发布(含并行收尾), 说明共用; 下一个版本再另立条目。
      '2.5.6' || '2.5.7' => [
        l10n.release253Hr,
        l10n.release253Permissions,
        l10n.release253Materials,
        l10n.release253Ai,
        l10n.release253Notices,
        l10n.release253Reset,
        l10n.release253Maintenance,
        l10n.release254QuantityPrecision,
        l10n.release254AiAuthorization,
        l10n.release254SensitiveAuthorization,
        l10n.release254OverLimit,
        l10n.release254PlanningReminders,
        l10n.release254PeoplePicker,
        l10n.release254AccountSupport,
        l10n.release254Dashboard,
        l10n.release254Publishing,
      ],
      '2.5.8' => [
        l10n.release258StatusColors,
        l10n.release258IqcPending,
        l10n.release258StockCount,
        l10n.release258CompactCells,
        l10n.release258LockReason,
      ],
      '2.5.9' => [
        l10n.release259RollbackMerge,
        l10n.release259SubcontractPending,
        l10n.release259InProgressGate,
        l10n.release259NoticeGrouping,
        l10n.release259PopupSettings,
        l10n.release259HrAndProfile,
      ],
      '2.5.10' => [
        l10n.release2510TableAlignment,
        l10n.release2510TransferOpen,
        l10n.release2510BatchReport,
        l10n.release2510FinanceRate,
        l10n.release2510NeedDate,
        l10n.release2510DirectTransfer,
        l10n.release2510SessionIdentity,
        l10n.release2510Misc,
      ],
      _ => <String>[],
    };
    final theme = Theme.of(context);
    return SelectionArea(
      child: AlertDialog(
        title: Text('${l10n.releaseNotesTitle} · $version'),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: notes.isEmpty
                  ? [Text(l10n.releaseNotesUnavailable)]
                  : [
                      for (var index = 0; index < notes.length; index++)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UtenSpacing.s16,
                          ),
                          child: Text(
                            '${index + 1}. ${notes[index]}',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                    ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.releaseNotesClose),
          ),
        ],
      ),
    );
  }
}
