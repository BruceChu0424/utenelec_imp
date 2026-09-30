import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/shell/pages/main_shell_page.dart';
import 'package:uten_imp/features/shell/widgets/floating_capsule_nav_bar.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/repositories/public_settings_repository.dart';

void main() {
  for (final width in [1440.0, 1920.0]) {
    testWidgets('collapsing navigation gives content more space at $width', (
      tester,
    ) async {
      final router = await _pumpShell(
        tester,
        width: width,
        height: width == 1440 ? 360 : 1000,
        brightness: width == 1440 ? Brightness.dark : Brightness.light,
      );
      final expandedWidth = tester.getSize(find.byKey(_surfaceKey)).width;
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        isTrue,
      );

      await tester.tap(find.byTooltip('收起导航栏'));
      await tester.pumpAndSettle();

      final collapsedWidth = tester.getSize(find.byKey(_surfaceKey)).width;
      expect(collapsedWidth, greaterThan(expandedWidth + 100));
      if (width == 1920) {
        // The old shell's 1600dp cap otherwise absorbs the recovered rail width.
        expect(collapsedWidth, greaterThan(1600));
      }
      expect(
        tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
        isFalse,
      );
      expect(find.byTooltip('展开导航栏'), findsOneWidget);
      expect(find.byTooltip('工作台'), findsOneWidget);
      expect(find.byTooltip('通知'), findsOneWidget);
      expect(router.routeInformationProvider.value.uri.path, '/shell-probe');

      await tester.tap(find.byTooltip('展开导航栏'));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byKey(_surfaceKey)).width,
        closeTo(expandedWidth, 0.01),
      );
      expect(find.byTooltip('收起导航栏'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('collapse and business navigation keep input and scroll state', (
    tester,
  ) async {
    final router = await _pumpShell(tester);
    final probe = tester.state<_BusinessProbeState>(
      find.byType(_BusinessProbe),
    );
    await tester.enterText(find.byKey(_inputKey), '保留正在编辑的内容');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.drag(find.byKey(_listKey), const Offset(0, -500));
    await tester.pumpAndSettle();
    final offset = probe.scrollController.offset;
    expect(offset, greaterThan(0));

    await tester.tap(find.byTooltip('收起导航栏'));
    await tester.pumpAndSettle();

    expect(
      tester.state<_BusinessProbeState>(find.byType(_BusinessProbe)),
      same(probe),
    );
    expect(probe.textController.text, '保留正在编辑的内容');
    expect(probe.scrollController.offset, closeTo(offset, 0.01));

    router.push('/shell-probe/detail');
    await tester.pumpAndSettle();
    expect(find.text('业务详情'), findsOneWidget);
    expect(find.byTooltip('展开导航栏'), findsOneWidget);
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
      isFalse,
    );

    router.pop();
    await tester.pumpAndSettle();
    expect(
      tester.state<_BusinessProbeState>(find.byType(_BusinessProbe)),
      same(probe),
    );
    expect(probe.textController.text, '保留正在编辑的内容');
    expect(probe.scrollController.offset, closeTo(offset, 0.01));
    expect(find.byTooltip('展开导航栏'), findsOneWidget);

    await tester.tap(find.byTooltip('展开导航栏'));
    await tester.pumpAndSettle();
    expect(
      tester.state<_BusinessProbeState>(find.byType(_BusinessProbe)),
      same(probe),
    );
    expect(probe.textController.text, '保留正在编辑的内容');
    expect(probe.scrollController.offset, closeTo(offset, 0.01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('responsive navigation preserves the manual desktop preference', (
    tester,
  ) async {
    await _pumpShell(tester, width: 1024);
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
      isFalse,
    );
    expect(find.byTooltip('收起导航栏'), findsNothing);
    expect(find.byTooltip('展开导航栏'), findsNothing);

    await _resize(tester, 1920);
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
      isTrue,
    );
    await tester.tap(find.byTooltip('收起导航栏'));
    await tester.pumpAndSettle();

    await _resize(tester, 1024);
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
      isFalse,
    );
    expect(find.byTooltip('展开导航栏'), findsNothing);

    await _resize(tester, 390);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(FloatingCapsuleNavBar), findsOneWidget);
    expect(find.byTooltip('展开导航栏'), findsNothing);

    await _resize(tester, 1920);
    expect(find.byType(FloatingCapsuleNavBar), findsNothing);
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
      isFalse,
    );
    expect(find.byTooltip('展开导航栏'), findsOneWidget);
    await tester.tap(find.byTooltip('展开导航栏'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationRail>(find.byType(NavigationRail)).extended,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

const _surfaceKey = Key('business-surface');
const _inputKey = Key('business-input');
const _listKey = Key('business-list');

Future<GoRouter> _pumpShell(
  WidgetTester tester, {
  double width = 1920,
  double height = 1000,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final router = GoRouter(
    // A cold business route exercises the real shell without initializing the
    // dashboard, notices, profile or settings pages and their repositories.
    initialLocation: '/shell-probe',
    routes: [
      ShellRoute(
        builder: (_, _, child) => MainShellPage(child: child),
        routes: [
          GoRoute(
            path: '/shell-probe',
            builder: (_, _) => const _BusinessProbe(),
            routes: [
              GoRoute(
                path: 'detail',
                builder: (_, _) =>
                    const Scaffold(body: Center(child: Text('业务详情'))),
              ),
            ],
          ),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        badgeTotalTodoProvider.overrideWithValue(5),
        unreadNoticeCountProvider.overrideWithValue(2),
        publicSettingsRepositoryProvider.overrideWithValue(
          const _PublicSettingsRepository(),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        theme: ThemeData(brightness: brightness),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

Future<void> _resize(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 1000);
  await tester.pumpAndSettle();
}

class _PublicSettingsRepository implements PublicSettingsRepository {
  const _PublicSettingsRepository();

  @override
  Future<PublicSettings> fetch() async => const PublicSettings();
}

class _BusinessProbe extends StatefulWidget {
  const _BusinessProbe();

  @override
  State<_BusinessProbe> createState() => _BusinessProbeState();
}

class _BusinessProbeState extends State<_BusinessProbe> {
  final textController = TextEditingController();
  final scrollController = ScrollController();

  @override
  void dispose() {
    textController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SizedBox.expand(
        key: _surfaceKey,
        child: Column(
          children: [
            TextField(key: _inputKey, controller: textController),
            Expanded(
              child: ListView.builder(
                key: _listKey,
                controller: scrollController,
                itemCount: 100,
                itemExtent: 48,
                itemBuilder: (_, index) => Text('业务记录 $index'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
