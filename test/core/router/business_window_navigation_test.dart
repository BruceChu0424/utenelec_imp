import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/business_window_host.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';

GoRouter _router() => GoRouter(
  initialLocation: '/editor',
  routes: [
    DraftAwareGoRoute(
      path: '/editor',
      builder: (_, _) => const Scaffold(body: Text('Editor')),
    ),
    DraftAwareGoRoute(
      path: '/record',
      builder: (_, _) => const Scaffold(body: Text('Record')),
    ),
  ],
);

Widget _app(
  GoRouter root,
  GoRouter window,
  WindowRouteInformation information,
) => MaterialApp.router(
  routerConfig: root,
  builder: (context, child) => Row(
    children: [
      Expanded(child: child!),
      Expanded(
        child: Router<Object>(
          routerDelegate: window.routerDelegate,
          routeInformationParser: window.routeInformationParser,
          routeInformationProvider: information,
        ),
      ),
    ],
  ),
);

void main() {
  testWidgets('window navigation and refresh never write browser history', (
    tester,
  ) async {
    final root = _router();
    final window = _router();
    final information = WindowRouteInformation(window);
    addTearDown(() {
      information.dispose();
      window.dispose();
      root.dispose();
    });
    final reports = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.navigation,
      (call) async {
        reports.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.navigation,
        null,
      ),
    );
    await tester.pumpWidget(_app(root, window, information));
    await tester.pumpAndSettle();
    reports.clear();
    window.push<void>('/record');
    await tester.pumpAndSettle();
    expect(root.state.uri.path, '/editor');
    expect(window.state.uri.path, '/record');
    window.pop();
    await tester.pumpAndSettle();
    window.refresh();
    await tester.pumpAndSettle();
    expect(window.state.uri.path, '/editor');
    window.go('/record');
    await tester.pumpAndSettle();
    window.replace<void>('/editor');
    await tester.pumpAndSettle();
    window.refresh();
    await tester.pumpAndSettle();
    expect(window.state.uri.path, '/editor');
    expect(reports, isEmpty);
    await tester.binding.handlePushRoute('/record');
    await tester.pumpAndSettle();
    expect(root.state.uri.path, '/record');
    expect(window.state.uri.path, '/editor');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'same-path editors own separate exit guards and close decisions',
    (tester) async {
      final root = _router();
      final window = _router();
      final information = WindowRouteInformation(window);
      final rootOwner = Object();
      final windowOwner = Object();
      var rootChecks = 0;
      var windowChecks = 0;
      var allowWindow = false;
      FormDraftNavigation.register(rootOwner, '/editor', () async {
        rootChecks++;
        return false;
      }, router: root);
      FormDraftNavigation.register(windowOwner, '/editor', () async {
        windowChecks++;
        return allowWindow;
      }, router: window);
      addTearDown(() {
        FormDraftNavigation.unregister(rootOwner);
        FormDraftNavigation.unregister(windowOwner);
        information.dispose();
        window.dispose();
        root.dispose();
      });
      await tester.pumpWidget(_app(root, window, information));
      await tester.pumpAndSettle();
      window.go('/record');
      await tester.pumpAndSettle();
      expect(window.state.uri.path, '/editor');
      expect(windowChecks, 1);
      expect(rootChecks, 0);
      expect(await FormDraftNavigation.confirmRouterExit(window), isFalse);
      expect(rootChecks, 0);
      allowWindow = true;
      expect(await FormDraftNavigation.confirmRouterExit(window), isTrue);
      window.go('/record');
      await tester.pumpAndSettle();
      expect(window.state.uri.path, '/record');
      expect(root.state.uri.path, '/editor');
      expect(rootChecks, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
