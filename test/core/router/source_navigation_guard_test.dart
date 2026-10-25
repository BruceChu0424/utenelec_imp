import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/nav_helpers.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';

void main() {
  testWidgets('draft navigation respects the source editor exit guard', (
    tester,
  ) async {
    final owner = Object();
    var allowExit = false;
    var exitChecks = 0;
    FormDraftNavigation.register(owner, '/editor', () async {
      exitChecks++;
      return allowExit;
    });
    addTearDown(() => FormDraftNavigation.unregister(owner));
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final editor = tester.element(find.text('Editor'));

    await tester.tap(find.text('Open drafts'));
    await tester.pumpAndSettle();
    expect(exitChecks, 1);
    expect(router.state.matchedLocation, '/editor');
    expect(find.text('Drafts'), findsNothing);
    expect(editor.mounted, isTrue);

    allowExit = true;
    await tester.tap(find.text('Open drafts'));
    await tester.pumpAndSettle();
    expect(exitChecks, 2);
    expect(router.state.matchedLocation, '/drafts');
    expect(router.state.uri.queryParameters['returnTo'], '/editor');
    expect(router.canPop(), isFalse);
    expect(editor.mounted, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('retained read navigation keeps its source mounted', (
    tester,
  ) async {
    final owner = Object();
    var exitChecks = 0;
    FormDraftNavigation.register(owner, '/editor', () async {
      exitChecks++;
      return false;
    });
    addTearDown(() => FormDraftNavigation.unregister(owner));
    final router = _router();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    final editor = tester.element(find.text('Editor'));

    await tester.tap(find.text('Open record'));
    await tester.pumpAndSettle();
    expect(router.state.matchedLocation, '/record');
    expect(router.state.uri.queryParameters['returnTo'], '/editor');
    expect(router.canPop(), isTrue);
    expect(editor.mounted, isTrue);
    expect(exitChecks, 0, reason: 'The source route has not been removed');

    await tester.tap(find.text('Return'));
    await tester.pumpAndSettle();
    expect(router.state.matchedLocation, '/editor');
    expect(tester.element(find.text('Editor')), same(editor));
    expect(exitChecks, 0);
    expect(tester.takeException(), isNull);
  });
}

GoRouter _router() => GoRouter(
  initialLocation: '/editor',
  routes: [
    DraftAwareGoRoute(
      path: '/editor',
      builder: (context, _) => Scaffold(
        body: Column(
          children: [
            const Text('Editor'),
            TextButton(
              onPressed: () => goFrom(context, '/drafts', retainSource: false),
              child: const Text('Open drafts'),
            ),
            TextButton(
              onPressed: () => goFrom(context, '/record'),
              child: const Text('Open record'),
            ),
          ],
        ),
      ),
    ),
    DraftAwareGoRoute(
      path: '/drafts',
      builder: (_, _) => const Scaffold(body: Text('Drafts')),
    ),
    DraftAwareGoRoute(
      path: '/record',
      builder: (context, _) => Scaffold(
        body: Column(
          children: [
            const Text('Record'),
            TextButton(
              onPressed: () => backTo(context, defaultPath: '/editor'),
              child: const Text('Return'),
            ),
          ],
        ),
      ),
    ),
  ],
);
