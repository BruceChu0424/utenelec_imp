import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';

Future<void> _paint(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

void main() {
  setUp(UtenBusyOverlay.debugResetYield);
  tearDown(UtenBusyOverlay.debugResetYield);

  testWidgets(
    'same event embedded state and pending run yield together without hiding new modal work',
    (tester) async {
      final continuation = Completer<void>();
      var showEmbedded = false;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setHostState) {
              return Scaffold(
                body: Stack(
                  children: [
                    TextButton(
                      onPressed: () {
                        setHostState(() => showEmbedded = true);
                        unawaited(
                          UtenBusyOverlay.run<void>(
                            context,
                            title: '待挂载run等待',
                            action: () async {
                              await UtenBusyOverlay.yieldWhile(
                                () => showDialog<void>(
                                  context: context,
                                  builder: (dialog) {
                                    return AlertDialog(
                                      title: const Text('统一让位确认'),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(dialog),
                                          child: const Text('结束统一确认'),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              );
                              await continuation.future;
                              if (context.mounted) {
                                setHostState(() => showEmbedded = false);
                              }
                            },
                          ),
                        );
                      },
                      child: const Text('开始混合等待'),
                    ),
                    if (showEmbedded)
                      const UtenBusyOverlay(
                        title: 'setState嵌入等待',
                        showDoNotLeaveHint: false,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('开始混合等待'));
      await _paint(tester);
      expect(find.text('统一让位确认'), findsOneWidget);
      expect(find.text('setState嵌入等待'), findsNothing);
      expect(find.text('待挂载run等待'), findsNothing);
      final nested = Completer<void>();
      final nestedWork = UtenBusyOverlay.run(
        tester.element(find.text('统一让位确认')),
        title: '确认里的新等待',
        action: () => nested.future,
      );
      await _paint(tester);
      expect(find.text('确认里的新等待'), findsOneWidget);
      expect(find.text('setState嵌入等待'), findsNothing);
      nested.complete();
      await _paint(tester);
      await nestedWork;
      await tester.tap(find.text('结束统一确认'));
      await _paint(tester);
      expect(find.text('setState嵌入等待'), findsOneWidget);
      expect(find.text('待挂载run等待'), findsOneWidget);
      continuation.complete();
      await tester.pumpAndSettle();
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('same event run yields its pending mask before dialog mount', (
    tester,
  ) async {
    var finished = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                await UtenBusyOverlay.run(
                  context,
                  title: '原请求等待',
                  action: () => UtenBusyOverlay.yieldWhile(
                    () => showDialog<void>(
                      context: context,
                      builder: (dialog) => AlertDialog(
                        title: const Text('交互确认'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialog),
                            child: const Text('继续原动作'),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
                finished = true;
              },
              child: const Text('开始'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await _paint(tester);
    expect(find.text('交互确认'), findsOneWidget);
    expect(find.text('原请求等待'), findsNothing);
    expect(finished, isFalse);
    await tester.tap(find.text('继续原动作'));
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(find.byType(UtenBusyOverlayCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new modal task owns its mask and outer resumes after yield', (
    tester,
  ) async {
    final inner = Completer<void>(), afterDialog = Completer<void>();
    var finished = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                await UtenBusyOverlay.run(
                  context,
                  title: '外层等待',
                  action: () async {
                    await UtenBusyOverlay.yieldWhile(
                      () => showDialog<void>(
                        context: context,
                        builder: (dialog) => AlertDialog(
                          title: const Text('二次确认'),
                          actions: [
                            TextButton(
                              onPressed: () => UtenBusyOverlay.run(
                                dialog,
                                title: '弹窗内核对',
                                action: () => inner.future,
                              ),
                              child: const Text('核对'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(dialog),
                              child: const Text('完成确认'),
                            ),
                          ],
                        ),
                      ),
                    );
                    await afterDialog.future;
                  },
                );
                finished = true;
              },
              child: const Text('开始'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await _paint(tester);
    expect(find.text('外层等待'), findsNothing);
    await tester.tap(find.text('核对'));
    await _paint(tester);
    expect(find.text('弹窗内核对'), findsOneWidget);
    expect(find.text('外层等待'), findsNothing);
    inner.complete();
    await _paint(tester);
    expect(find.text('弹窗内核对'), findsNothing);
    await tester.tap(find.text('完成确认'));
    await _paint(tester);
    expect(find.text('外层等待'), findsOneWidget);
    expect(finished, isFalse);
    afterDialog.complete();
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(find.byType(UtenBusyOverlayCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending yield exception retires only its run owner', (
    tester,
  ) async {
    Object? caught;
    final held = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                try {
                  await UtenBusyOverlay.run<void>(
                    context,
                    title: '将失败的等待',
                    action: () => UtenBusyOverlay.yieldWhile<void>(() async {
                      await held.future;
                      throw StateError('核对失败');
                    }),
                  );
                } catch (error) {
                  caught = error;
                }
              },
              child: const Text('开始'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await _paint(tester);
    expect(find.text('将失败的等待'), findsNothing);
    held.complete();
    await tester.pumpAndSettle();
    expect(caught, isA<StateError>());
    expect(find.byType(UtenBusyOverlayCard), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
