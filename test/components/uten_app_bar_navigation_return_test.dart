import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/nav_helpers.dart';
import 'package:uten_imp/features/basic_data/widgets/master_record_history_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

Future<void> _return(GoRouter router, WidgetTester tester, String mode) async {
  switch (mode) {
    case 'pop':
      router.pop();
    case 'go':
      router.go('/source');
    case 'platform':
      await router.routeInformationProvider.didPushRouteInformation(
        RouteInformation(uri: Uri.parse('/source')),
      );
    case 'replace':
      router.replace<void>('/replacement');
      await tester.pumpAndSettle();
      router.pop();
  }
  await tester.pumpAndSettle();
}

Future<void> _tapAction(WidgetTester tester, String label) async {
  final overflow = find.byKey(const Key('uten-app-bar-more-actions'));
  if (overflow.hitTestable().evaluate().isNotEmpty) {
    await tester.tap(overflow);
    // A ShellRoute's nested header remains current beneath the root panel.
    // Advance its opening transition without waiting for that covered action.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }
  final text = find.text(label).hitTestable();
  await tester.tap(
    text.evaluate().isNotEmpty ? text.first : find.byTooltip(label).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final kind in ['native', 'uten', 'header']) {
    for (final mode in ['pop', 'go', 'platform', 'replace']) {
      for (final width in [320.0, 1200.0]) {
        testWidgets(
          '$kind pure header navigation reopens after $mode at $width',
          (tester) async {
            await tester.binding.setSurfaceSize(Size(width, 900));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            var opened = 0;
            final router = GoRouter(
              initialLocation: '/source',
              routes: [
                GoRoute(
                  path: '/source',
                  builder: (context, _) {
                    void open() => pushPage(
                      context,
                      '/detail?returnTo=%2Fsource',
                      extra: 'original-intent',
                    );
                    final action = switch (kind) {
                      'native' => IconButton(
                        tooltip: 'open detail',
                        onPressed: open,
                        icon: const Icon(Icons.open_in_new),
                      ),
                      'uten' => UtenButton(
                        onPressed: open,
                        child: const Text('open detail'),
                      ),
                      _ => UtenAppBarActionButton(
                        label: 'open detail',
                        onPressed: open,
                      ),
                    };
                    return Scaffold(
                      appBar: UtenAppBar(
                        title: 'navigation source',
                        showPagePermissionAction: false,
                        actions: [
                          action,
                          IconButton(
                            tooltip: 'refresh fixture',
                            onPressed: () {},
                            icon: const Icon(Icons.refresh),
                          ),
                          TextButton(
                            onPressed: () {},
                            child: const Text('other'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                GoRoute(
                  path: '/detail',
                  builder: (_, state) {
                    opened++;
                    expect(state.uri.queryParameters['returnTo'], '/source');
                    expect(state.extra, 'original-intent');
                    return const Scaffold(body: Text('detail page'));
                  },
                ),
                GoRoute(
                  path: '/replacement',
                  builder: (_, _) => const Scaffold(body: Text('replacement')),
                ),
              ],
            );
            addTearDown(router.dispose);
            await tester.pumpWidget(
              ProviderScope(
                child: MaterialApp.router(
                  routerConfig: router,
                  locale: const Locale('zh'),
                  localizationsDelegates:
                      AppLocalizations.localizationsDelegates,
                  supportedLocales: AppLocalizations.supportedLocales,
                ),
              ),
            );
            await tester.pumpAndSettle();
            for (var visit = 0; visit < 2; visit++) {
              await _tapAction(tester, 'open detail');
              expect(find.text('detail page'), findsOneWidget);
              await _return(router, tester, mode);
            }
            expect(opened, 2);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }

  for (final scenario in [
    for (final mode in ['pop', 'go', 'platform', 'replace'])
      for (final width in [320.0, 1200.0])
        for (final shell in [false, true])
          (mode: mode, width: width, shell: shell),
  ]) {
    testWidgets('master-history header preserves restoration $scenario', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(scenario.width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var refreshed = 0;
      final routes = <RouteBase>[
        GoRoute(
          path: '/source',
          builder: (_, _) => Scaffold(
            appBar: UtenAppBar(
              title: '货品资料',
              showPagePermissionAction: false,
              actions: [
                MasterRecordHistoryAction(
                  entityType: 'goods',
                  recordId: 'goods-1',
                  onChanged: () => refreshed++,
                ),
                IconButton(
                  tooltip: 'refresh fixture',
                  onPressed: () {},
                  icon: const Icon(Icons.refresh),
                ),
                TextButton(onPressed: () {}, child: const Text('other')),
              ],
            ),
          ),
        ),
        GoRoute(
          path: '/basicinfo/history',
          builder: (_, state) {
            expect(state.uri.queryParameters['entityType'], 'goods');
            expect(state.uri.queryParameters['recordId'], 'goods-1');
            return const Scaffold(body: Text('history page'));
          },
        ),
        GoRoute(
          path: '/replacement',
          builder: (_, _) => const Scaffold(body: Text('replacement')),
        ),
      ];
      final router = GoRouter(
        initialLocation: '/source',
        routes: scenario.shell
            ? [ShellRoute(builder: (_, _, child) => child, routes: routes)]
            : routes,
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentPermissionsProvider.overrideWithValue({Perm.goodsView}),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (var visit = 0; visit < 2; visit++) {
        await _tapAction(tester, '修改历史');
        expect(find.text('history page'), findsOneWidget);
        expect(find.byTooltip('关闭操作面板').hitTestable(), findsNothing);
        (router.state.extra as ValueNotifier<bool>).value = true;
        await _return(router, tester, scenario.mode);
        expect(refreshed, visit + 1);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
