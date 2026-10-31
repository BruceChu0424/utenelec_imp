import 'package:flutter_riverpod/legacy.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/core/router/business_window_host.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import 'package:uten_imp/shared/windows/business_windows.dart';

void main() {
  testWidgets(
    'one common window entry covers basic-data pages and where-used',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          // These synthetic routes exercise hosting; the real route policy is
          // verified separately, including revoked effective permissions.
          businessLocationAllowedProvider.overrideWith((ref, location) => true),
          sensitiveReadBoundaryProvider.overrideWithValue(
            SensitiveReadBoundary(
              identity: null,
              api: ApiClient(Dio()),
              permissions: {},
              superAdmin: false,
            ),
          ),
          businessWindowRouterProvider.overrideWith((ref, window) {
            final router = GoRouter(
              navigatorKey: window.navigatorKey,
              initialLocation: window.location,
              routes: [
                GoRoute(
                  path: window.location,
                  builder: (_, _) =>
                      const Scaffold(body: Text('Independent record')),
                ),
              ],
            );
            ref.onDispose(router.dispose);
            return router;
          }),
        ],
      );
      addTearDown(container.dispose);
      const supported = [
        '/basicinfo',
        '/basicinfo/mould',
        '/basicinfo/goods/a',
        '/basicinfo/units',
        '/basicinfo/colors',
        '/basicinfo/supplier',
        '/basicinfo/currency',
        '/production/where-used',
      ];
      final root = GoRouter(
        initialLocation: supported.first,
        routes: [
          ShellRoute(
            builder: (_, _, child) => BusinessWindowHost(child: child),
            routes: [
              for (final path in [...supported, '/sales/order'])
                GoRoute(
                  path: path,
                  builder: (_, _) => const Scaffold(
                    appBar: UtenAppBar(
                      title: '资料',
                      showPagePermissionAction: false,
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
      addTearDown(root.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: root),
        ),
      );
      final windows = container.read(businessWindowsProvider);
      for (final path in supported) {
        root.go(path);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('business-open-window')), findsOneWidget);
        await tester.tap(find.byKey(const Key('business-open-window')));
        await tester.pumpAndSettle();
        expect(windows.windows.single.location, path);
        expect(root.state.uri.path, path);
        expect(find.text('Independent record'), findsOneWidget);
        windows.clear();
        await tester.pumpAndSettle();
      }
      root.go('/sales/order');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('business-open-window')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );

  testWidgets(
    'windows tile without remounting drafts, close safely and clear on scope change',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final boundary = SensitiveReadBoundary(
        identity: null,
        api: ApiClient(Dio()),
        permissions: {},
        superAdmin: false,
      );
      var allowClose = false;
      final liveBoundary = StateProvider((ref) => boundary);
      final container = ProviderContainer(
        overrides: [
          businessLocationAllowedProvider.overrideWith((ref, location) => true),
          sensitiveReadBoundaryProvider.overrideWith(
            (ref) => ref.watch(liveBoundary),
          ),
          businessWindowRouterProvider.overrideWith((ref, window) {
            final router = GoRouter(
              navigatorKey: window.navigatorKey,
              initialLocation: window.location,
              routes: [
                DraftAwareGoRoute(
                  path: '/editor',
                  builder: (_, _) =>
                      Scaffold(body: TextField(key: ValueKey(window.title))),
                ),
              ],
            );
            FormDraftNavigation.register(
              window,
              '/editor',
              () async => allowClose,
              router: router,
            );
            ref.onDispose(() {
              FormDraftNavigation.unregister(window);
              router.dispose();
            });
            return router;
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: BusinessWindowHost(child: Text('Main table'))),
          ),
        ),
      );
      final windows = container.read(businessWindowsProvider);
      windows.open('/editor', 'A');
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('A')), 'unsaved A');
      windows.open('/editor', 'B');
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('B')), 'unsaved B');
      await tester.tap(find.byTooltip('并排排列所有窗口').last);
      await tester.pumpAndSettle();
      final a = windows.windows[0].windowKey.currentState!.bounds;
      final b = windows.windows[1].windowKey.currentState!.bounds;
      expect(a.overlaps(b), isFalse);
      expect(find.text('unsaved A'), findsOneWidget);
      expect(find.text('unsaved B'), findsOneWidget);
      expect(find.byType(UtenFloatingWindow), findsNWidgets(2));
      // Close requests consult only the owning window's edit guard.
      final lastWindow = tester.widget<UtenFloatingWindow>(
        find.byType(UtenFloatingWindow).last,
      );
      lastWindow.onClose();
      await tester.pumpAndSettle();
      expect(windows.windows, hasLength(2));
      allowClose = true;
      lastWindow.onClose();
      await tester.pumpAndSettle();
      expect(windows.windows, hasLength(1));
      expect(find.text('unsaved A'), findsOneWidget);
      container.read(liveBoundary.notifier).state = SensitiveReadBoundary(
        identity: null,
        api: ApiClient(Dio()),
        permissions: {},
        superAdmin: false,
      );
      await tester.pumpAndSettle();
      expect(windows.windows, isEmpty);
      expect(find.byType(UtenFloatingWindow), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a stale window action and direct open cannot bypass revocation',
    (tester) async {
      const location = '/basicinfo/goods/saved-record';
      final api = ApiClient(Dio());
      SensitiveReadBoundary boundary(Set<String> permissions) =>
          SensitiveReadBoundary(
            identity: null,
            api: api,
            permissions: permissions,
            superAdmin: true,
          );
      final liveBoundary = StateProvider((ref) => boundary({Perm.goodsView}));
      final container = ProviderContainer(
        overrides: [
          sensitiveReadBoundaryProvider.overrideWith(
            (ref) => ref.watch(liveBoundary),
          ),
          businessWindowRouterProvider.overrideWith((ref, window) {
            final router = GoRouter(
              initialLocation: location,
              routes: [
                GoRoute(
                  path: location,
                  builder: (_, _) =>
                      const Scaffold(body: Text('Authorized record')),
                ),
              ],
            );
            ref.onDispose(router.dispose);
            return router;
          }),
        ],
      );
      addTearDown(container.dispose);
      final router = GoRouter(
        initialLocation: location,
        routes: [
          GoRoute(
            path: location,
            builder: (_, _) => const BusinessWindowHost(
              child: Scaffold(
                appBar: UtenAppBar(
                  title: '资料',
                  showPagePermissionAction: false,
                ),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      final action = find.byKey(const Key('business-open-window'));
      final staleAction = tester
          .widget<UtenAppBarActionButton>(action)
          .onPressed!;
      final windows = container.read(businessWindowsProvider);
      container.read(liveBoundary.notifier).state = boundary({
        Perm.productionWhereUsedView,
      });
      await tester.pumpAndSettle();
      await Future<void>.sync(staleAction);
      expect(windows.open(location, 'Saved callback'), isFalse);
      expect(windows.windows, isEmpty);
      expect(action, findsNothing);
      container.read(liveBoundary.notifier).state = boundary({Perm.goodsView});
      await tester.pumpAndSettle();
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(windows.windows, hasLength(1));
      expect(find.text('Authorized record'), findsOneWidget);
      container.read(liveBoundary.notifier).state = boundary({});
      await tester.pumpAndSettle();
      expect(windows.windows, isEmpty);
      expect(find.text('Authorized record'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
