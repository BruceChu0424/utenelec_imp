import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_task_progress_dialog.dart';

void main() {
  testWidgets('任务开始前显示等待，完成后只关闭自己的等待框', (tester) async {
    final completion = Completer<void>();
    late BuildContext pageContext;
    var started = false;
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
                      task: () {
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
}
