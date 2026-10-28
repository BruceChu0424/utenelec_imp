import 'package:flutter/material.dart';
import '../../../components/layout/uten_section_header.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';

/// Entry remains available while runtime policy settings are loading or fail.
class PlatformSettingsEntryCard extends ConsumerWidget {
  const PlatformSettingsEntryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = platformSettingsAllowedFor(
      ref.watch(currentPermissionsProvider),
      ref.watch(isSuperAdminProvider),
    );
    if (!allowed) return const SizedBox.shrink();
    final theme = Theme.of(context);
    void open() {
      if (!platformSettingsAllowedFor(
        ref.read(currentPermissionsProvider),
        ref.read(isSuperAdminProvider),
      )) {
        return;
      }
      context.push(RouteName.adminPlatformSettings);
    }

    return Semantics(
      button: true,
      label: '平台设置，公司名称、Logo、主题色、服务器与配置入口',
      onTap: open,
      excludeSemantics: true,
      child: Card(
        key: const ValueKey('system-settings-platform-entry'),
        margin: const EdgeInsets.only(bottom: UtenSpacing.s12),
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: UtenRadius.controlAll,
          side: BorderSide(color: theme.dividerColor),
        ),
        child: InkWell(
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Row(
              children: [
                Icon(
                  Icons.business_outlined,
                  size: 32,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s12),
                const Expanded(
                  child: UtenSectionHeader(
                    title: '平台设置',
                    info: '公司名称、Logo、主题色、服务器与配置入口',
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
