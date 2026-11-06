import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/feedback/uten_task_progress_dialog.dart';
import 'package:uten_imp/shared/widgets/reauth_dialog.dart';

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 12; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(UtenBusyOverlay.debugResetYield);
  tearDown(UtenBusyOverlay.debugResetYield);
  testWidgets('实际等待卡片绘制后才开始任务，不用定时延迟', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold(body: Text('原页面'));
          },
        ),
      ),
    );
    final completion = Completer<void>();
    var calls = 0;
    var paintedAtStart = false;
    final pending = runUtenBlockingTask<void>(
      context: context,
      title: '实际绘制',
      task: () {
        calls++;
        paintedAtStart =
            find.byType(UtenBusyOverlayCard).evaluate().length == 1 &&
            find.text('实际绘制').evaluate().length == 1;
        return completion.future;
      },
    );
    await tester.pump();
    expect(calls, 0);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump();
    expect(calls, 1);
    expect(paintedAtStart, isTrue);
    expect(find.text('实际绘制'), findsOneWidget);
    completion.complete();
    await tester.pumpAndSettle();
    await pending;
    expect(find.byType(UtenTaskProgressDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('卡片绘制前撤权不执行任务且关闭所属弹窗', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const Scaffold(body: Text('原页面'));
          },
        ),
      ),
    );
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    var calls = 0;
    Object? failure;
    final pending =
        runUtenBlockingTask<void>(
          context: context,
          title: '撤权前等待',
          invalidation: revision,
          isCurrent: () => revision.value == 0,
          task: () async {
            calls++;
          },
        ).then<void>(
          (_) {},
          onError: (Object error, StackTrace _) {
            failure = error;
          },
        );
    await tester.pump();
    expect(calls, 0);
    revision.value++;
    await tester.pumpAndSettle();
    await pending;
    expect(calls, 0);
    expect(failure, isA<StateError>());
    expect(find.byType(UtenTaskProgressDialog), findsNothing);
    expect(find.byType(UtenBusyOverlayCard), findsNothing);
    expect(find.text('原页面'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('任务开始前显示等待，完成后只关闭自己的等待框', (tester) async {
    final completion = Completer<void>();
    late BuildContext pageContext;
    var started = false;
    var paintedBeforeTask = false;
    ModalRoute<void>? ownedRoute;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pageContext = context;
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  unawaited(
                    runUtenBlockingTask<void>(
                      context: context,
                      title: '正在删除分类…',
                      onRouteCreated: (route) => ownedRoute = route,
                      task: () {
                        paintedBeforeTask = find
                            .byType(UtenBusyOverlayCard)
                            .evaluate()
                            .isNotEmpty;
                        started = true;
                        return completion.future;
                      },
                    ),
                  );
                },
                child: const Text('删除'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('正在删除分类…'), findsOneWidget);
    expect(started, isTrue);
    expect(paintedBeforeTask, isTrue);
    expect(ownedRoute!.barrierColor, Colors.transparent);
    expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
    expect(find.textContaining('请勿重复点击'), findsNothing);
    await Navigator.of(pageContext).maybePop();
    await tester.pump();
    expect(find.text('正在删除分类…'), findsOneWidget);
    unawaited(
      showDialog<void>(
        context: pageContext,
        builder: (_) => const AlertDialog(title: Text('后续弹窗')),
      ),
    );
    await tester.pump();
    completion.complete();
    await tester.pumpAndSettle();
    expect(find.text('正在删除分类…'), findsNothing);
    expect(find.text('后续弹窗'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('身份变化关闭旧等待框而不取消已发送的任务', (tester) async {
    final completion = Completer<void>();
    final revision = ValueNotifier<int>(0);
    addTearDown(revision.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  final initial = revision.value;
                  unawaited(
                    runUtenBlockingTask<void>(
                      context: context,
                      title: '正在导出…',
                      invalidation: revision,
                      isCurrent: () => revision.value == initial,
                      task: () => completion.future,
                    ),
                  );
                },
                child: const Text('导出'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('导出'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('正在导出…'), findsOneWidget);
    revision.value++;
    await tester.pumpAndSettle();
    expect(find.text('正在导出…'), findsNothing);
    expect(completion.isCompleted, isFalse);
    completion.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('初始等待失效后不开始任务，自己的路由仍被精确清理', (tester) async {
    final revision = ValueNotifier(0);
    addTearDown(revision.dispose);
    var calls = 0;
    Object? error;
    ModalRoute<void>? ownedRoute;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  unawaited(
                    runUtenBlockingTask<void>(
                      context: context,
                      title: '尚未发送',
                      task: () async {
                        calls++;
                      },
                      isCurrent: () => revision.value == 0,
                      invalidation: revision,
                      onRouteCreated: (route) => ownedRoute = route,
                    ).catchError((Object value) {
                      error = value;
                    }),
                  );
                },
                child: const Text('开始'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    expect(ownedRoute, isNotNull);
    revision.value++;
    await _frames(tester);
    expect(calls, 0);
    expect(error, isA<StateError>());
    expect(ownedRoute!.isActive, isFalse);
    expect(find.byType(UtenBusyOverlayCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已退役任务的晚finally不关闭新等待路由', (tester) async {
    final revision = ValueNotifier(0);
    addTearDown(revision.dispose);
    final first = Completer<void>(), second = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  final epoch = revision.value;
                  final index = ++calls;
                  unawaited(
                    runUtenBlockingTask<void>(
                      context: context,
                      title: index == 1 ? '旧任务' : '新任务',
                      task: () => index == 1 ? first.future : second.future,
                      isCurrent: () => revision.value == epoch,
                      invalidation: revision,
                    ),
                  );
                },
                child: const Text('开始'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await _frames(tester);
    revision.value++;
    await _frames(tester);
    expect(find.byType(UtenBusyOverlayCard), findsNothing);
    await tester.tap(find.text('开始'));
    await _frames(tester);
    expect(find.text('新任务'), findsOneWidget);
    first.complete();
    await _frames(tester);
    expect(find.text('新任务'), findsOneWidget);
    expect(second.isCompleted, isFalse);
    second.complete();
    await tester.pumpAndSettle();
    expect(find.byType(UtenBusyOverlayCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('真实再认证让位，新核验仍显示自己的统一等待，返回后恢复原任务', (tester) async {
    final verification = Completer<String>(), continuation = Completer<void>();
    var finished = false;
    var verificationCalls = 0, taskCalls = 0;
    String? verifiedToken;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  unawaited(
                    runUtenBlockingTask<void>(
                      context: context,
                      title: '导出处理中',
                      task: () async {
                        taskCalls++;
                        verifiedToken = await showReauthDialog(
                          context,
                          verify: (_) {
                            verificationCalls++;
                            return verification.future;
                          },
                        );
                        await continuation.future;
                        finished = true;
                      },
                    ),
                  );
                },
                child: const Text('开始'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await _frames(tester);
    expect(find.byKey(const Key('reauth-dialog')), findsOneWidget);
    expect(find.text('导出处理中'), findsNothing);
    await tester.enterText(
      find.byKey(const Key('reauth-password')),
      'synthetic-only',
    );
    await tester.tap(find.byKey(const Key('reauth-confirm')));
    await _frames(tester);
    expect(find.text('正在验证身份'), findsOneWidget);
    expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
    expect(verificationCalls, 1);
    expect(taskCalls, 1);
    expect(find.text('导出处理中'), findsNothing);
    verification.complete('task-owned-token');
    await _frames(tester);
    expect(find.byKey(const Key('reauth-dialog')), findsNothing);
    expect(find.text('导出处理中'), findsOneWidget);
    expect(verifiedToken, 'task-owned-token');
    expect(finished, isFalse);
    continuation.complete();
    await tester.pumpAndSettle();
    expect(finished, isTrue);
    expect(verificationCalls, 1);
    expect(taskCalls, 1);
    expect(find.byType(UtenBusyOverlayCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('再认证取消能真实点击且不发送后续写入', (tester) async {
    var writes = 0, finished = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  unawaited(
                    runUtenBlockingTask<void>(
                      context: context,
                      title: '等待身份确认',
                      task: () async {
                        final token = await showReauthDialog(
                          context,
                          verify: (_) async => 'unused-token',
                        );
                        if (token != null) writes++;
                      },
                    ).whenComplete(() => finished = true),
                  );
                },
                child: const Text('开始'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await _frames(tester);
    expect(find.text('等待身份确认'), findsNothing);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(finished, isTrue);
    expect(find.byType(UtenBusyOverlayCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('任务异常只移除自己的等待，不关闭已经打开的结果层', (tester) async {
    final completion = Completer<void>();
    Object? error;
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pageContext = context;
            return Scaffold(
              body: TextButton(
                onPressed: () {
                  unawaited(
                    runUtenBlockingTask<void>(
                      context: context,
                      title: '将失败的任务',
                      task: () => completion.future,
                    ).catchError((Object value) {
                      error = value;
                    }),
                  );
                },
                child: const Text('开始'),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await _frames(tester);
    unawaited(
      showDialog<void>(
        context: pageContext,
        builder: (dialog) {
          return AlertDialog(
            title: const Text('独立结果'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('关闭结果'),
              ),
            ],
          );
        },
      ),
    );
    await _frames(tester);
    expect(find.text('将失败的任务'), findsNothing);
    completion.completeError(StateError('合成任务失败'));
    await tester.pumpAndSettle();
    expect(error, isA<StateError>());
    expect(find.text('独立结果'), findsOneWidget);
    expect(find.byType(UtenBusyOverlayCard), findsNothing);
    await tester.tap(find.text('关闭结果'));
    await tester.pumpAndSettle();
    expect(find.text('独立结果'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
