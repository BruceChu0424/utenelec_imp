import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/router/nav_helpers.dart';
import 'package:uten_imp/shared/drafts/form_draft_dialog_resume.dart';

class _PageStateProbe extends StatelessWidget {
  const _PageStateProbe({required this.name, required this.observe});

  final String name;
  final void Function(String name, BuildContext context, GoRouterState? state)
  observe;

  @override
  Widget build(BuildContext context) {
    observe(name, context, goRouterPageStateOrNull(context));
    return Text('probe:$name');
  }
}

void main() {
  testWidgets(
    'route state stays with its own page when another page is pushed',
    (tester) async {
      final contexts = <String, BuildContext>{};
      final states = <String, GoRouterState?>{};
      void observe(String name, BuildContext context, GoRouterState? state) {
        contexts[name] = context;
        states[name] = state;
      }

      final router = GoRouter(
        initialLocation: '/host?draftId=original&draftForm=master',
        routes: [
          for (final name in ['host', 'other'])
            GoRoute(
              path: '/$name',
              builder: (_, _) => Scaffold(
                body: _PageStateProbe(name: name, observe: observe),
              ),
            ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      final originalKey = states['host']!.pageKey;
      router.push('/other?draftId=second');
      await tester.pumpAndSettle();

      expect(states['other']!.uri.queryParameters['draftId'], 'second');
      final host = goRouterPageStateOrNull(contexts['host']!);
      expect(host!.uri.path, '/host');
      expect(host.uri.queryParameters['draftId'], 'original');
      expect(host.pageKey, originalKey);
      expect(dialogDraftId(contexts['host']!, kind: 'master'), 'original');
      expect(dialogDraftPageKey(contexts['host']!), originalKey);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'imperative page and dialog never inherit the host draft identity',
    (tester) async {
      final contexts = <String, BuildContext>{};
      final states = <String, GoRouterState?>{};
      void observe(String name, BuildContext context, GoRouterState? state) {
        contexts[name] = context;
        states[name] = state;
      }

      final router = GoRouter(
        initialLocation: '/host?draftId=host-draft&draftForm=master',
        routes: [
          GoRoute(
            path: '/host',
            builder: (_, _) => Scaffold(
              body: _PageStateProbe(name: 'host', observe: observe),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      Navigator.of(contexts['host']!).push<void>(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            body: _PageStateProbe(name: 'imperative', observe: observe),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(states.containsKey('imperative'), isTrue);
      expect(states['imperative'], isNull);
      expect(dialogDraftId(contexts['imperative']!), isNull);
      expect(dialogDraftPageKey(contexts['imperative']!), isNull);
      expect(dialogDraftParameters(contexts['imperative']!), isEmpty);
      expect(
        currentLocationOr(contexts['imperative']!, '/explicit'),
        '/explicit',
      );
      expect(tester.takeException(), isNull);
      Navigator.of(contexts['imperative']!).pop();
      await tester.pumpAndSettle();

      showDialog<void>(
        context: contexts['host']!,
        builder: (_) => AlertDialog(
          content: _PageStateProbe(name: 'dialog', observe: observe),
        ),
      );
      await tester.pumpAndSettle();
      expect(states.containsKey('dialog'), isTrue);
      expect(states['dialog'], isNull);
      expect(dialogDraftId(contexts['dialog']!), isNull);
      expect(dialogDraftPageKey(contexts['dialog']!), isNull);
      expect(dialogDraftParameters(contexts['dialog']!), isEmpty);
      expect(tester.takeException(), isNull);
      Navigator.of(contexts['dialog']!).pop();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
