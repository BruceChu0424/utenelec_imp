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
    final notes = normalized == '2.5.3'
        ? [
            l10n.release253Hr,
            l10n.release253Permissions,
            l10n.release253Materials,
            l10n.release253Ai,
            l10n.release253Notices,
            l10n.release253Reset,
            l10n.release253Maintenance,
          ]
        : <String>[];
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
