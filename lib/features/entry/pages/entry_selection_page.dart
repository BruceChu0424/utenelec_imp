// 入口选择页（登录前）：内部人员 / 访客。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';

class EntrySelectionPage extends StatelessWidget {
  const EntrySelectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [UtenColors.deepGreen, UtenColors.teal500],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(builder: (context, c) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: c.maxHeight),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: UtenCard(
                        padding: const EdgeInsets.all(28),
                        borderRadius: 20,
                        elevation: UtenCardElevation.high,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildLogo(),
                            const SizedBox(height: 20),
                            Text(l10n.entryTitle,
                                style: theme.textTheme.headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                                textAlign: TextAlign.center),
                            const SizedBox(height: 6),
                            Text(l10n.entrySubtitle,
                                style: theme.textTheme.bodyMedium
                                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                textAlign: TextAlign.center),
                            const SizedBox(height: 28),
                            UtenButton(
                              isExpanded: true,
                              size: UtenButtonSize.large,
                              icon: Icons.badge_rounded,
                              onPressed: () => context.go(RouteName.login),
                              child: Text(l10n.entryStaff),
                            ),
                            const SizedBox(height: 8),
                            Text(l10n.entryStaffDesc,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                textAlign: TextAlign.center),
                            const SizedBox(height: 20),
                            UtenButton(
                              isExpanded: true,
                              size: UtenButtonSize.large,
                              type: UtenButtonType.secondary,
                              icon: Icons.qr_code_2_rounded,
                              onPressed: () => context.go(RouteName.visitorLogin),
                              child: Text(l10n.entryVisitor),
                            ),
                            const SizedBox(height: 8),
                            Text(l10n.entryVisitorDesc,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                                textAlign: TextAlign.center),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Center(
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [UtenColors.teal500, UtenColors.teal400],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: UtenColors.teal500.withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, 6)),
          ],
        ),
        child: const Center(
          child: Text('U',
              style: TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w800)),
        ),
      ),
    );
  }
}
