// 入口选择页（登录前）：内部人员 / 访客。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/brand/uten_wordmark_logo.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/route_names.dart';

class EntrySelectionPage extends StatelessWidget {
  const EntrySelectionPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isCompact = MediaQuery.sizeOf(context).width < 480;
    final pagePadding = isCompact ? 20.0 : 24.0;
    final cardPadding = isCompact ? 24.0 : 32.0;
    final logoWidth = isCompact ? 200.0 : 220.0;

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          color: isDark ? null : theme.scaffoldBackgroundColor,
          gradient: isDark
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF07110E), Color(0xFF0F241D)],
                )
              : null,
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, c) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: c.maxHeight),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Padding(
                        padding: EdgeInsets.all(pagePadding),
                        child: UtenCard(
                          padding: EdgeInsets.all(cardPadding),
                          borderRadius: 16,
                          elevation: UtenCardElevation.high,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Center(
                                child: UtenWordmarkLogo(
                                  width: logoWidth,
                                  height: logoWidth / (405 / 74),
                                ),
                              ),
                              const SizedBox(height: 24),
                              Text(
                                l10n.entrySubtitle,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 24),
                              UtenButton(
                                isExpanded: true,
                                size: UtenButtonSize.large,
                                icon: Icons.badge_rounded,
                                onPressed: () => context.go(RouteName.login),
                                child: Text(l10n.entryStaff),
                              ),
                              const SizedBox(height: 16),
                              UtenButton(
                                isExpanded: true,
                                size: UtenButtonSize.large,
                                type: UtenButtonType.secondary,
                                icon: Icons.qr_code_2_rounded,
                                onPressed: () =>
                                    context.go(RouteName.visitorLogin),
                                child: Text(l10n.entryVisitor),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
