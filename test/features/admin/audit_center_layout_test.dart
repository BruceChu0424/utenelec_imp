import '../../support/audit_screenshot_support.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/pages/admin_audit_log_page.dart';
import 'package:uten_imp/features/admin/widgets/audit_query_scope.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/repositories/public_settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final width in [375.0, 768.0, 1440.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'audit viewport $width dark=$dark keeps content and supports large text',
        (tester) async {
          SharedPreferences.setMockInitialValues(const {});
          final preferences = await SharedPreferences.getInstance();
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          const capture = bool.fromEnvironment('UTEN_CAPTURE_UI');
          if (capture) await loadAuditScreenshotFonts(tester);
          final boundaryKey = GlobalKey();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                sharedPreferencesProvider.overrideWithValue(preferences),
                publicSettingsRepositoryProvider.overrideWithValue(
                  const _PublicSettingsRepository(),
                ),
              ],
              child: MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh'),
                theme: capture
                    ? auditScreenshotTheme(buildLightTheme())
                    : buildLightTheme(),
                darkTheme: capture
                    ? auditScreenshotTheme(buildDarkTheme())
                    : buildDarkTheme(),
                themeMode: dark ? ThemeMode.dark : ThemeMode.light,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: const TextScaler.linear(1.3),
                    disableAnimations: true,
                  ),
                  child: RepaintBoundary(key: boundaryKey, child: child),
                ),
                home: const AdminAuditLogPage(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('audit-select-actor')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          if (capture) {
            await saveAuditScreenshot(
              tester,
              boundaryKey,
              'audit-${width.toInt()}-${dark ? 'dark' : 'light'}',
            );
          }
        },
      );
    }
  }

  testWidgets(
    '375px audit center keeps the person selector in the first viewport',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            publicSettingsRepositoryProvider.overrideWithValue(
              const _PublicSettingsRepository(),
            ),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('zh'),
            home: AdminAuditLogPage(),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('建立审计调查范围'), findsOneWidget);
      expect(find.text('待选人员'), findsOneWidget);
      final selectActor = find.byKey(const ValueKey('audit-select-actor'));
      expect(selectActor, findsOneWidget);
      expect(tester.getRect(selectActor).bottom, lessThanOrEqualTo(812));
      expect(find.text('一次调查，只走三步'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('query composer keeps the two-step flow touch friendly', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpComposer(tester, controller: controller);

    expect(find.text('选择调查对象'), findsOneWidget);
    expect(find.text('选择查看日期'), findsOneWidget);
    expect(find.text('已完成 0 / 2 步'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('audit-select-actor'))).height,
      greaterThanOrEqualTo(48),
    );
    final today = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('audit-date-today')),
    );
    expect(today.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'applied person and Beijing range collapse into a concise summary',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpComposer(
        tester,
        controller: controller,
        selectedActor: const AuditActorOption(
          actorId: '11111111-1111-4111-8111-111111111111',
          displayName: '张三（销售一部）',
          department: '销售部',
          position: '业务员',
        ),
        dateRange: DateTimeRange(
          start: DateTime.utc(2026, 8, 28),
          end: DateTime.utc(2026, 8, 30),
        ),
        scopeApplied: true,
      );

      expect(find.text('调查范围已应用'), findsNothing);
      expect(find.text('已加载范围'), findsNothing);
      expect(find.textContaining('2026-08-28 至 2026-08-30'), findsWidgets);
      expect(
        find.byKey(const ValueKey('audit-date-today')),
        findsNothing,
        reason: '查询后范围编辑器应收起，给会话列表留出首屏空间',
      );

      await tester.tap(find.byKey(const ValueKey('audit-scope-expansion')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('audit-date-today')), findsOneWidget);
      expect(find.text('重新加载登录会话'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dark mode large text and landscape keep the query flow usable', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpComposer(
      tester,
      controller: controller,
      darkMode: true,
      textScale: 1.5,
    );

    expect(
      Theme.of(
        tester.element(find.byKey(const ValueKey('audit-select-actor'))),
      ).brightness,
      Brightness.dark,
    );
    expect(find.text('选择调查对象'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(812, 375);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('audit-select-actor')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpComposer(
  WidgetTester tester, {
  required TextEditingController controller,
  AuditActorOption? selectedActor,
  DateTimeRange? dateRange,
  bool scopeApplied = false,
  bool darkMode = false,
  double textScale = 1,
}) async {
  SharedPreferences.setMockInitialValues(const {});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        theme: ThemeData(colorSchemeSeed: Colors.teal),
        darkTheme: ThemeData(
          brightness: Brightness.dark,
          colorSchemeSeed: Colors.teal,
        ),
        themeMode: darkMode ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: AuditQueryScopeComposer(
                selectedActor: selectedActor,
                anonymousMode: false,
                systemAnomalyMode: false,
                dateRange: dateRange,
                requestIdController: controller,
                requestInvestigation: false,
                loading: false,
                scopeApplied: scopeApplied,
                onPickActor: () {},
                onSelectAnonymous: () {},
                onSelectSystemAnomaly: () {},
                onToday: () {},
                onYesterday: () {},
                onSevenDays: () {},
                onThirtyDays: () {},
                onCustomDate: () {},
                onRunQuery: () {},
                onRequestIdChanged: (_) {},
                onRequestIdSubmitted: (_) {},
                onClear: () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _PublicSettingsRepository implements PublicSettingsRepository {
  const _PublicSettingsRepository();

  @override
  Future<PublicSettings> fetch() async => const PublicSettings();
}
