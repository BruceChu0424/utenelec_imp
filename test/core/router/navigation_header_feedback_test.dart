import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/router/nav_helpers.dart';

Future<GoRouter> _pump(
  WidgetTester tester, {
  required VoidCallback onOpen,
  required Future<void> Function() onWrite,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          appBar: UtenAppBar(
            title: 'source',
            actions: [
              UtenButton(
                onPressed: () => pushPage(context, '/detail?tab=lines'),
                child: const Text('open detail'),
              ),
              UtenButton(onPressed: onWrite, child: const Text('save data')),
            ],
          ),
          body: const Text('source content'),
        ),
      ),
      GoRoute(
        path: '/detail',
        builder: (_, state) {
          onOpen();
          expect(state.uri.queryParameters, {'tab': 'lines'});
          return const Scaffold(body: Text('detail'));
        },
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  for (final browser in [false, true]) {
    testWidgets('navigation-only header action reopens after go: $browser', (
      tester,
    ) async {
      var opened = 0;
      final router = await _pump(
        tester,
        onOpen: () => opened++,
        onWrite: () async {},
      );
      for (var visit = 1; visit <= 2; visit++) {
        await tester.tap(find.text('open detail'));
        await tester.pumpAndSettle();
        expect(opened, visit);
        if (browser) {
          await router.routeInformationProvider.didPushRouteInformation(
            RouteInformation(uri: Uri.parse('/')),
          );
        } else {
          router.go('/');
        }
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('returning never releases a real pending header write', (
    tester,
  ) async {
    final write = Completer<void>();
    var starts = 0;
    var completions = 0;
    final router = await _pump(
      tester,
      onOpen: () {},
      onWrite: () async {
        starts++;
        await write.future;
        completions++;
      },
    );
    await tester.tap(find.text('save data'));
    await tester.pump();
    pushPage(tester.element(find.text('source content')), '/detail?tab=lines');
    await tester.pumpAndSettle();
    router.go('/');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final save = find.ancestor(
      of: find.text('save data'),
      matching: find.byType(UtenButton),
    );
    final ink = find.descendant(of: save, matching: find.byType(InkWell));
    expect(tester.widget<InkWell>(ink).onTap, isNull);
    expect(starts, 1);
    expect(completions, 0);
    write.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<InkWell>(ink).onTap, isNotNull);
    expect(completions, 1);
    expect(tester.takeException(), isNull);
  });
}
