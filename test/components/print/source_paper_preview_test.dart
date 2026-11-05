@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';

void main() {
  testWidgets(
    'source preview never paints a generic table and cancel retires pending font/PDF work',
    (tester) async {
      final data =
          jsonDecode(
                File(
                  'contracts/finance-paper-layout/v1.json',
                ).readAsStringSync(),
              )
              as Map;
      final fixture = Map<String, dynamic>.from(
        data['supplierStatement'] as Map,
      );
      final font = Completer<ByteData?>();
      var requested = false;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMessageHandler('flutter/assets', (message) {
        final name = utf8.decode(message!.buffer.asUint8List());
        if (name == 'assets/fonts/NotoSansSCFull.ttf') {
          requested = true;
          return font.future;
        }
        return Future.value();
      });
      addTearDown(
        () => messenger.setMockMessageHandler('flutter/assets', null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenPrintPreviewButton(
              title: '匿名完整原件',
              applyTableProjection: false,
              loader: () async => UtenPrintTable(
                headers: List<String>.from(fixture['headers'] as List),
                rows: [
                  for (final row in fixture['rows'] as List)
                    List<String>.from(row as List),
                ],
                documentMetadata: {'paperLayout': fixture['layout']},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.bySemanticsLabel('预览打印'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-output-all')));
      for (
        var frame = 0;
        frame < 8 && find.text('取消读取').evaluate().isEmpty;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(requested, isTrue);
      expect(find.text('取消读取'), findsOneWidget);
      expect(find.byKey(const ValueKey('uten-print-paper-list')), findsNothing);
      await tester.tap(find.text('取消读取'));
      await tester.pumpAndSettle();
      font.complete(ByteData(0));
      await tester.pump();
      await tester.pump();
      expect(find.text('预览 · 匿名完整原件'), findsNothing);
      expect(find.text('正在生成原件预览'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
