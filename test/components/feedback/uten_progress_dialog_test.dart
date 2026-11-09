import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_progress_dialog.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

final _zh = lookupAppLocalizations(const Locale('zh'));

/// 可由测试逐步驱动的「工作」: 拿到会话后挂起, 直到测试放行。
class _Driver {
  final completer = Completer<String>();
  UtenProgressSession? session;

  Future<String> call(UtenProgressSession progress) {
    session = progress;
    return completer.future;
  }
}

/// 逐项写入的批量: 每项一次「写请求」(由测试逐个放行), 开始下一项前看取消。
/// 必须在测试体内创建: Completer 绑定创建时的 zone, 放到 setUp 会脱离 fake async。
class _WriteBatch {
  final writes = List.generate(4, (_) => Completer<void>());
  final started = <int>[];

  Future<String> call(UtenProgressSession progress) async {
    const total = 4;
    var done = 0;
    for (var i = 0; i < total; i++) {
      if (progress.isCancelled) break;
      started.add(i);
      progress.count(done, total, status: '正在提交');
      await writes[i].future;
      done++;
      progress.count(done, total, status: '正在提交');
    }
    return '已完成 $done / $total';
  }
}

class _Launch {
  Future<String?>? result;
  Object? error;
}

Widget _app(Widget home) => MaterialApp(
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: buildLightTheme(),
  home: Scaffold(body: Center(child: home)),
);

Future<_Launch> _open(
  WidgetTester tester,
  _Driver driver, {
  String? initialStatus,
  bool cancellable = true,
  UtenProgressCancel cancelMode = UtenProgressCancel.immediate,
  Future<String> Function(UtenProgressSession progress)? action,
}) async {
  final launch = _Launch();
  await tester.pumpWidget(
    _app(
      Builder(
        builder: (context) => TextButton(
          onPressed: () {
            launch.result = showUtenProgress<String>(
              context,
              title: '正在导出货品资料',
              initialStatus: initialStatus ?? '正在生成文件',
              cancellable: cancellable,
              cancelMode: cancelMode,
              action: action ?? driver.call,
            );
            launch.result!.then(
              (_) {},
              onError: (Object e) {
                launch.error = e;
              },
            );
          },
          child: const Text('go'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pump();
  // 帧后再启动 action。
  await tester.pump();
  return launch;
}

void main() {
  testWidgets('percent mode shows figure, detail, elapsed and cancel; '
      'never a spinner', (tester) async {
    final driver = _Driver();
    final launch = await _open(tester, driver);

    expect(find.text('正在导出货品资料'), findsOneWidget);
    expect(find.text('正在生成文件'), findsOneWidget);
    expect(find.text(_zh.progressElapsed('0:00')), findsOneWidget);
    expect(find.text(_zh.progressCancel), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('uten-progress-cancel'))).height,
      greaterThanOrEqualTo(48),
    );
    // 全项目进度弹窗不出现转圈(规范: 导出/下载/批量等待用进度条)。
    expect(find.byType(CircularProgressIndicator), findsNothing);

    driver.session!.count(3, 5, detail: '3,200 / 5,300 行');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('uten-progress-percent')), findsOneWidget);
    expect(find.text('60'), findsOneWidget);
    expect(find.text('正在生成文件'), findsOneWidget);
    expect(find.text('3,200 / 5,300 行'), findsOneWidget);

    driver.completer.complete('done.xlsx');
    await tester.pumpAndSettle();
    expect(find.text('正在导出货品资料'), findsNothing);
    expect(await launch.result, 'done.xlsx');
  });

  testWidgets('unknown totals show the sweep bar and status headline, '
      'never a fake percent', (tester) async {
    final driver = _Driver();
    final launch = await _open(tester, driver);

    driver.session!.stage('正在与服务器核对数据');
    await tester.pump();
    expect(find.byKey(const ValueKey('uten-progress-status')), findsOneWidget);
    expect(find.byKey(const ValueKey('uten-progress-percent')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    driver.completer.complete('done');
    await tester.pumpAndSettle();
    expect(await launch.result, 'done');
  });

  testWidgets('count and percent clamp out-of-range input', (tester) async {
    final driver = _Driver();
    final launch = await _open(tester, driver);

    driver.session!.count(9, 5);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('uten-progress-percent')), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('5 / 5'), findsOneWidget);

    driver.session!.percent(-2, status: '正在下载');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('0'), findsOneWidget);
    expect(find.text('正在下载'), findsOneWidget);

    driver.completer.complete('done');
    await tester.pumpAndSettle();
    expect(await launch.result, 'done');
  });

  testWidgets('cancel closes at once, returns null and flags the session; '
      'later errors are swallowed', (tester) async {
    final driver = _Driver();
    final launch = await _open(tester, driver);

    await tester.tap(find.byKey(const ValueKey('uten-progress-cancel')));
    await tester.pumpAndSettle();

    expect(find.text('正在导出货品资料'), findsNothing);
    expect(await launch.result, isNull);
    expect(driver.session!.isCancelled, isTrue);
    await driver.session!.whenCancelled;
    // 取消后工作再出错也不会打扰用户。
    driver.completer.completeError(StateError('late'));
    await tester.pumpAndSettle();
    expect(launch.error, isNull);
  });

  testWidgets('system back cancels instead of orphaning the work', (
    tester,
  ) async {
    final driver = _Driver();
    final launch = await _open(tester, driver);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(await launch.result, isNull);
    expect(driver.session!.isCancelled, isTrue);
  });

  testWidgets('a failure closes the dialog and rethrows the original error', (
    tester,
  ) async {
    final driver = _Driver();
    final launch = await _open(tester, driver);

    driver.completer.completeError(StateError('服务器拒绝'));
    await tester.pumpAndSettle();

    expect(find.text('正在导出货品资料'), findsNothing);
    expect(launch.error, isA<StateError>());
  });

  testWidgets('long waits show a reassurance line', (tester) async {
    final driver = _Driver();
    await _open(tester, driver);
    await tester.pump(const Duration(seconds: 29));
    expect(find.text(_zh.progressSlowHint), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(_zh.progressSlowHint), findsOneWidget);
    driver.completer.complete('done');
    await tester.pumpAndSettle();
  });

  group('afterCurrent (write batches)', () {
    testWidgets('cancel keeps the dialog until the in-flight item finishes, '
        'then returns the real partial result', (tester) async {
      final batch = _WriteBatch();
      final launch = await _open(
        tester,
        _Driver(),
        cancelMode: UtenProgressCancel.afterCurrent,
        action: batch.call,
      );
      batch.writes[0].complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('25'), findsOneWidget);
      expect(find.text('1 / 4'), findsOneWidget, reason: '计数详情随进度更新');
      expect(batch.started, [0, 1]);

      // 第 2 项在途时点取消: 弹窗不关, 按钮变「正在停止」且禁用, 显示停止说明。
      await tester.tap(find.byKey(const ValueKey('uten-progress-cancel')));
      await tester.pump();
      expect(find.text('正在导出货品资料'), findsOneWidget);
      expect(find.text(_zh.progressStoppingButton), findsOneWidget);
      expect(
        find.byKey(const ValueKey('uten-progress-stopping')),
        findsOneWidget,
      );
      final button = tester.widget<UtenButton>(
        find.byKey(const ValueKey('uten-progress-cancel')),
      );
      expect(button.onPressed, isNull, reason: '点过一次后不可重复点');
      // 再点、再按返回都不会关掉弹窗或中断在途写入。
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('正在导出货品资料'), findsOneWidget);

      batch.writes[1].complete();
      await tester.pumpAndSettle();
      expect(find.text('正在导出货品资料'), findsNothing);
      expect(batch.started, [0, 1], reason: '取消后不再开始下一项');
      expect(await launch.result, '已完成 2 / 4');
    });

    testWidgets('a write failure after cancel is still reported, '
        'not swallowed as a cancellation', (tester) async {
      final batch = _WriteBatch();
      final launch = await _open(
        tester,
        _Driver(),
        cancelMode: UtenProgressCancel.afterCurrent,
        action: batch.call,
      );
      await tester.tap(find.byKey(const ValueKey('uten-progress-cancel')));
      await tester.pump();

      batch.writes[0].completeError(StateError('服务器拒绝'));
      await tester.pumpAndSettle();
      expect(find.text('正在导出货品资料'), findsNothing);
      expect(launch.error, isA<StateError>());
    });

    testWidgets('system back drains the same way as the cancel button', (
      tester,
    ) async {
      final batch = _WriteBatch();
      final launch = await _open(
        tester,
        _Driver(),
        cancelMode: UtenProgressCancel.afterCurrent,
        action: batch.call,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('正在导出货品资料'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('uten-progress-stopping')),
        findsOneWidget,
      );

      batch.writes[0].complete();
      await tester.pumpAndSettle();
      expect(await launch.result, '已完成 1 / 4');
    });
  });

  testWidgets('a non-cancellable wait offers neither cancel nor close and '
      'ignores system back', (tester) async {
    final driver = _Driver();
    final launch = await _open(tester, driver, cancellable: false);

    expect(find.byKey(const ValueKey('uten-progress-cancel')), findsNothing);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
    expect(find.text(_zh.progressElapsed('0:00')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('正在导出货品资料'), findsOneWidget);
    expect(driver.session!.isCancelled, isFalse);

    driver.completer.complete('done');
    await tester.pumpAndSettle();
    expect(await launch.result, 'done');
  });

  testWidgets('onRouteOpened hands out the live dialog route and invalidation '
      'retires the wait', (tester) async {
    final driver = _Driver();
    final routes = <ModalRoute<dynamic>>[];
    final invalidation = ValueNotifier<int>(0);
    final launch = _Launch();
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () {
              launch.result = showUtenProgress<String>(
                context,
                title: '正在导出货品资料',
                initialStatus: '正在生成文件',
                invalidation: invalidation,
                onRouteOpened: routes.add,
                action: driver.call,
              );
              launch.result!.then(
                (_) {},
                onError: (Object e) {
                  launch.error = e;
                },
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump();

    // 弹窗路由在顶, 调用方可以用它做「自己弹窗压顶不算其他页面」的守卫。
    expect(routes, hasLength(1));
    expect(routes.single.isCurrent, isTrue);
    expect(driver.session, isNotNull);
    expect(driver.session!.isCancelled, isFalse);

    // 身份/服务器切换: 弹窗按取消收尾, 结果不再呈现。
    invalidation.value++;
    await tester.pump();
    await tester.pump();
    expect(find.text('正在导出货品资料'), findsNothing);
    expect(await launch.result, isNull);
    expect(launch.error, isNull);

    // 迟到的工作结果被吞掉, 不再弹提示。
    driver.completer.complete('late');
    await tester.pumpAndSettle();
    invalidation.dispose();
  });
}
