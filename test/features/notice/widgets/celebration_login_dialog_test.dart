import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'package:uten_imp/components/effects/celebration_particles.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/widgets/celebration_login_dialog.dart';
import 'package:uten_imp/features/notice/widgets/celebration_mascot.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';

class _LitePerformance extends PerformanceNotifier {
  @override
  PerformanceTier build() => PerformanceTier.lite;
}

void main() {
  for (final size in [const Size(375, 844), const Size(1280, 900)]) {
    testWidgets(
      'celebration keeps its art and closes from the header at $size',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              performanceProvider.overrideWith(_LitePerformance.new),
              platformBrandingSnapshotProvider.overrideWithValue(
                PlatformBranding.defaults,
              ),
            ],
            child: MaterialApp(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Consumer(
                builder: (context, ref, _) => Scaffold(
                  body: TextButton(
                    onPressed: () => showCelebrationLoginDialog(
                      context,
                      ref,
                      const MyCelebrationToday(
                        type: NoticeType.birthday,
                        subjectName: '测试员工',
                        eventLabel: '',
                      ),
                    ),
                    child: const Text('打开庆典'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开庆典'));
        await tester.pumpAndSettle();

        final close = find.byKey(const Key('celebration-login-close'));
        final art = find.byType(CelebrationMascot);
        final l10n = AppLocalizations.of(tester.element(close));
        expect(art, findsOneWidget);
        expect(find.byType(CelebrationParticleField), findsOneWidget);
        expect(
          find.text(l10n.celebrationPopupBirthday('测试员工').split('\n').first),
          findsOneWidget,
        );
        expect(find.text(l10n.celebrationDismiss), findsNothing);
        expect(
          tester.getRect(close).left,
          greaterThan(tester.getCenter(art).dx),
        );
        expect(tester.getRect(close).top, lessThan(tester.getCenter(art).dy));
        expect(close.hitTestable(), findsOneWidget);
        expect(find.byType(UtenCloseButton), findsOneWidget);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(art, findsNothing);
        expect(find.text('打开庆典'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
