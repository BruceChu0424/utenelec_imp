import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_log.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_navigation.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_store.dart';

class _Store implements DiagnosticStore {
  final text = StringBuffer();
  @override
  String? get directory => null;
  @override
  Future<void> append(String lines) async => text.write(lines);
  @override
  Future<Uint8List> readRecent() async =>
      Uint8List.fromList(utf8.encode('$text'));
  @override
  Future<void> openDirectory() async {}
}

void main() {
  testWidgets(
    'navigation logs committed templates and detaches with its owner',
    (tester) async {
      final store = _Store();
      final previous = AppDiagnostics.log;
      final log = DiagnosticLog(store);
      AppDiagnostics.log = log;
      addTearDown(() => AppDiagnostics.log = previous);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SizedBox()),
          GoRoute(path: '/goods/:id', builder: (_, _) => const SizedBox()),
        ],
      );
      addTearDown(router.dispose);
      final detach = attachDiagnosticNavigation(router);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      router.go('/goods/private-customer-name?search=private-input');
      await tester.pumpAndSettle();
      await log.flush();
      final lines = store.text
          .toString()
          .trim()
          .split('\n')
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      expect(lines.last['path'], '/goods/:id');
      expect(store.text.toString(), isNot(contains('private')));
      detach();
      final count = lines.length;
      router.go('/');
      await tester.pumpAndSettle();
      await log.flush();
      expect(store.text.toString().trim().split('\n'), hasLength(count));
    },
  );
}
