import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../components/layout/uten_section_header.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/gen/app_localizations.dart';
import 'client_release_access.dart';
import '../../core/router/nav_helpers.dart';
import '../../core/router/route_names.dart';
import 'client_update_controller.dart';
import 'client_update_page.dart';

class ClientUpdateTile extends ConsumerWidget {
  const ClientUpdateTile({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kIsWeb) return const SizedBox.shrink();
    final controller = ref.watch(clientUpdateControllerProvider);
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          Icons.system_update_alt_rounded,
          color: Theme.of(context).colorScheme.primary,
        ),
        title: Text(l10n.clientUpdateTitle),
        subtitle: Text(
          controller.release == null
              ? l10n.clientUpdateSubtitle
              : '${l10n.clientUpdateLatest} ${controller.release!.version}',
        ),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => openClientUpdatePage(context, controller),
      ),
    );
  }
}

class ClientReleasePublishTile extends ConsumerWidget {
  const ClientReleasePublishTile({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(clientReleasePublisherProvider) == null) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.publish_rounded),
      title: UtenSectionHeader(
        title: l10n.clientUpdatePublishTitle,
        info: l10n.clientUpdatePublishHint,
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () {
        if (ref.read(clientReleasePublisherProvider) == null) return;
        pushPage(context, RouteName.clientReleasePublish);
      },
    );
  }
}
