import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../components/brand/uten_brand_mascot.dart';
import '../../../components/brand/uten_wordmark_logo.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/platform_branding/platform_branding.dart';
import '../../../shared/widgets/desktop_window_host.dart';

/// Desktop sign-in presentation only. The owning page keeps its one form,
/// controllers, validation and authentication flow through [formBuilder].
class DesktopLoginLayout extends StatelessWidget {
  const DesktopLoginLayout({
    super.key,
    required this.branding,
    required this.formBuilder,
  });

  final PlatformBranding branding;
  final Widget Function(bool showBrand) formBuilder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final accessibilityScale =
          (MediaQuery.textScalerOf(context).scale(36) / 36).clamp(
            1.0,
            double.infinity,
          );
      final compact =
          constraints.maxWidth < 680 * accessibilityScale ||
          constraints.maxHeight < 440 * accessibilityScale;
      // Construct exactly one form, including when display zoom changes the
      // layout. Authentication state belongs to LoginPage, never this layout.
      final form = formBuilder(compact);
      if (compact) {
        return ColoredBox(
          key: const Key('desktop-login-form-panel'),
          color: Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.only(
              top: DesktopWindowHost.controlsHeight,
            ),
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.hasBoundedHeight
                      ? (constraints.maxHeight -
                                DesktopWindowHost.controlsHeight)
                            .clamp(0.0, double.infinity)
                      : 0,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UtenSpacing.s24,
                    16,
                    UtenSpacing.s24,
                    UtenSpacing.s24,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [form],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 45,
            child: _DesktopBrandPanel(
              key: const Key('desktop-login-brand-panel'),
              branding: branding,
            ),
          ),
          Expanded(
            flex: 55,
            child: _DesktopFormPanel(
              key: const Key('desktop-login-form-panel'),
              form: form,
            ),
          ),
        ],
      );
    },
  );
}

class _DesktopBrandPanel extends StatelessWidget {
  const _DesktopBrandPanel({super.key, required this.branding});

  final PlatformBranding branding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final base = Color.alphaBlend(
      theme.colorScheme.primary.withValues(alpha: dark ? 0.04 : 0.05),
      theme.colorScheme.surface,
    );
    return ColoredBox(
      color: base,
      child: Padding(
        padding: const EdgeInsets.only(top: DesktopWindowHost.controlsHeight),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s24),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (!branding.usesDefaultArtwork) {
                return const Center(
                  child: UtenWordmarkLogo(width: 200, height: 60),
                );
              }
              const logoHeight = 170 / (405 / 74);
              final mascotSize = math.min(
                220.0,
                math.min(
                  constraints.maxWidth,
                  math.max(
                    0.0,
                    constraints.maxHeight - UtenSpacing.s20 - logoHeight,
                  ),
                ),
              );
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    UtenBrandMascot.size(mascotSize),
                    const SizedBox(height: UtenSpacing.s20),
                    const UtenWordmarkLogo(width: 170, height: logoHeight),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DesktopFormPanel extends StatelessWidget {
  const _DesktopFormPanel({super.key, required this.form});

  final Widget form;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final copy = _LoginCopy.forLanguage(
      Localizations.localeOf(context).languageCode,
    );
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.only(top: DesktopWindowHost.controlsHeight),
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 340),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          copy.welcome,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontSize: 26,
                            height: 1.25,
                            letterSpacing: -0.4,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s8),
                        Text(
                          copy.signInHint,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 14,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s20),
                        form,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoginCopy {
  const _LoginCopy({required this.welcome, required this.signInHint});

  final String welcome;
  final String signInHint;

  static _LoginCopy forLanguage(String language) => switch (language) {
    'en' => const _LoginCopy(
      welcome: 'Welcome back',
      signInHint: 'Continue with your employee account',
    ),
    'ko' => const _LoginCopy(
      welcome: '다시 오신 것을 환영합니다',
      signInHint: '직원 계정으로 계속하세요',
    ),
    _ => const _LoginCopy(welcome: '欢迎回来', signInHint: '使用你的员工账号继续'),
  };
}
