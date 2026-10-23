import 'package:flutter/material.dart';
import '../../components/buttons/uten_button.dart';
import '../../components/cards/uten_card.dart';
import '../../components/layout/uten_content_container.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_tokens.dart';
import 'client_update_controller.dart';

Future<void> openClientUpdatePage(
  BuildContext context,
  ClientUpdateController controller,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/settings/software-update'),
    builder: (_) => ClientUpdatePage(controller: controller),
  );
  void ownerChanged() {
    if (route.isActive) navigator.removeRoute(route);
  }

  controller.addOwnerDisposedListener(ownerChanged);
  try {
    await navigator.push(route);
  } finally {
    controller.removeOwnerDisposedListener(ownerChanged);
  }
}

class ClientUpdatePage extends StatelessWidget {
  const ClientUpdatePage({super.key, required this.controller});
  final ClientUpdateController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final theme = Theme.of(context);
      final release = controller.release;
      final installed = controller.installed;
      final downloading = controller.stage == ClientUpdateStage.downloading;
      final installing = controller.stage == ClientUpdateStage.installing;
      final supported =
          release?.installMode == 'store' ||
          installed?.supportsInPlaceUpdate == true;
      final status = controller.stage == ClientUpdateStage.checking
          ? l10n.clientUpdateChecking
          : controller.error != null
          ? l10n.clientUpdateFailed
          : controller.hasSuccessfulCheck
          ? l10n.clientUpdateUpToDate
          : l10n.clientUpdateSubtitle;
      final hint = release?.installMode == 'store'
          ? l10n.clientUpdateStoreHint
          : installed?.platform == 'windows'
          ? l10n.clientUpdateWindowsHint
          : installed?.platform == 'android'
          ? l10n.clientUpdateAndroidHint
          : l10n.clientUpdateUnsupported;

      final action = UtenCard(
        padding: const EdgeInsets.all(UtenSpacing.s24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.clientUpdateCurrent, style: theme.textTheme.bodySmall),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              installed?.currentVersion ?? '',
              style: theme.textTheme.titleLarge,
            ),
            if (release != null) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: UtenSpacing.s16),
                child: Divider(height: 1),
              ),
              Text(l10n.clientUpdateLatest, style: theme.textTheme.bodySmall),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                release.version,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
              if (release.sizeBytes > 0)
                Text(
                  '${(release.sizeBytes / 1048576).toStringAsFixed(1)} MB',
                  style: theme.textTheme.bodySmall,
                ),
              const SizedBox(height: UtenSpacing.s24),
              Text(
                supported ? hint : l10n.clientUpdateUnsupported,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (downloading || installing) ...[
                const SizedBox(height: UtenSpacing.s24),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    downloading
                        ? '${l10n.clientUpdateDownloading} ${(controller.progress * 100).floor()}%'
                        : l10n.clientUpdateInstalling,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s12),
                LinearProgressIndicator(
                  value: downloading ? controller.progress : null,
                ),
              ],
              if (controller.stage == ClientUpdateStage.installerOpened) ...[
                const SizedBox(height: UtenSpacing.s16),
                Text(
                  release.installMode == 'store'
                      ? l10n.clientUpdateStoreHint
                      : installed?.platform == 'windows'
                      ? l10n.clientUpdateInstalling
                      : l10n.clientUpdateInstallerOpened,
                ),
              ],
              if (controller.error != null ||
                  installed?.lastUpdateFailed == true) ...[
                const SizedBox(height: UtenSpacing.s16),
                Text(
                  l10n.clientUpdateFailed,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: UtenSpacing.s24),
              if (supported)
                UtenButton(
                  isExpanded: true,
                  isLoading: controller.transferBusy,
                  icon: Icons.download_rounded,
                  onPressed:
                      controller.busy ||
                          controller.stage == ClientUpdateStage.installerOpened
                      ? null
                      : controller.update,
                  child: Text(l10n.clientUpdateNow),
                ),
            ] else ...[
              const SizedBox(height: UtenSpacing.s16),
              Text(
                installed?.supportsInPlaceUpdate == false &&
                        !{'ios', 'macos'}.contains(installed?.platform)
                    ? l10n.clientUpdateUnsupported
                    : status,
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
            UtenButton(
              type: UtenButtonType.ghost,
              isLoading: controller.stage == ClientUpdateStage.checking,
              onPressed: controller.transferBusy
                  ? null
                  : () => controller.check(),
              child: Text(l10n.clientUpdateCheck),
            ),
          ],
        ),
      );
      final notes = UtenCard(
        padding: const EdgeInsets.all(UtenSpacing.s24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.clientUpdateNotes, style: theme.textTheme.titleLarge),
            const SizedBox(height: UtenSpacing.s24),
            Text(
              release?.releaseNotes.isNotEmpty == true
                  ? release!.releaseNotes
                  : l10n.clientUpdateNoNotes,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.8),
            ),
          ],
        ),
      );
      return PopScope(
        canPop: !controller.transferBusy,
        child: Scaffold(
          appBar: AppBar(
            title: Text(l10n.clientUpdateTitle),
            leading: BackButton(
              onPressed: controller.transferBusy
                  ? null
                  : () => Navigator.of(context).maybePop(),
            ),
          ),
          body: UtenContentContainer(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: UtenSpacing.s16,
                    runSpacing: UtenSpacing.s12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(UtenSpacing.s16),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: UtenRadius.cardAll,
                        ),
                        child: Icon(
                          Icons.system_update_alt_rounded,
                          size: 32,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            release == null
                                ? l10n.clientUpdateTitle
                                : '${l10n.clientUpdateLatest} ${release.version}',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: UtenSpacing.s4),
                          Text(
                            l10n.clientUpdateSubtitle,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s24),
                  LayoutBuilder(
                    builder: (context, bounds) {
                      final largeText =
                          MediaQuery.textScalerOf(context).scale(16) > 24;
                      if (bounds.maxWidth < 840 || largeText) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            action,
                            const SizedBox(height: UtenSpacing.s24),
                            if (release != null) notes,
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 3, child: notes),
                          const SizedBox(width: UtenSpacing.s24),
                          Expanded(flex: 2, child: action),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
