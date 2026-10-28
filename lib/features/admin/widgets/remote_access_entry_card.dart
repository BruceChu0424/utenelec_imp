import 'package:flutter/material.dart';
import '../../../components/layout/uten_section_header.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/auth/permissions.dart';
import '../../../core/l10n/remote_access_text.dart';

class RemoteAccessEntryCard extends ConsumerWidget {
  const RemoteAccessEntryCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    bool allowed() => platformSettingsAllowedFor(
      ref.read(currentPermissionsProvider),
      ref.read(isSuperAdminProvider),
    );
    if (!platformSettingsAllowedFor(
      ref.watch(currentPermissionsProvider),
      ref.watch(isSuperAdminProvider),
    )) {
      return const SizedBox.shrink();
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      child: ListTile(
        key: const Key('remote-access-settings-entry'),
        leading: const Icon(Icons.public_outlined),
        title: UtenSectionHeader(
          title: remoteAccessText(context, 'title'),
          info: remoteAccessText(context, 'description'),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          if (allowed()) context.push(RouteName.adminRemoteAccess);
        },
      ),
    );
  }
}
