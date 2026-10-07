import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/ai/ai_job_models.dart';
import 'package:uten_imp/shared/ai/ai_job_repository.dart';
import 'package:uten_imp/shared/ai/ai_job_runner.dart';
import 'package:uten_imp/shared/ai/ai_progress_dialog.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';

final _zh = lookupAppLocalizations(const Locale('zh'));

const _stages = [
  AiProgressStage(key: AiJobSnapshot.uploadingStage, label: '上传文件'),
  AiProgressStage(key: 'READ', label: '读取表格', serverStages: ['READING']),
  AiProgressStage(
    key: 'LAYOUT',
    label: '识别表头与列',
    serverStages: ['LAYOUT', 'AI_LAYOUT'],
  ),
  AiProgressStage(
    key: 'GOODS',
    label: '匹配货品',
    serverStages: ['MATCHING_GOODS'],
  ),
];

AiJobSnapshot _snap({
  String id = 'job-1',
  AiJobStatus status = AiJobStatus.running,
  String? stage,
  Map<String, dynamic>? result,
}) => AiJobSnapshot(
  id: id,
  kind: 'SALES_DOCUMENT_INTAKE',
  status: status,
  stage: stage,
  result: result,
);

/// 可由测试逐步驱动的作业。
class _Driver {
  final completer = Completer<AiJobSnapshot>();
  AiJobProgressCallback? progress;
  AiJobCancelToken? token;

  Future<AiJobSnapshot> call(
    AiJobProgressCallback onProgress,
    AiJobCancelToken cancelToken,
  ) {
    progress = onProgress;
    token = cancelToken;
    return completer.future;
  }
}

class _Launch {
  Future<AiJobSnapshot?>? result;
  Object? error;
}

Widget _app(Widget home, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: RepaintBoundary(
        key: const Key('ai-progress-capture'),
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildLightTheme(),
          home: Scaffold(body: Center(child: home)),
        ),
      ),
    );

/// 只在显式要求时落盘(`UTEN_UI_FIXTURES=1 flutter test ...`)。
Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['UTEN_UI_FIXTURES'] != '1') return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('ai-progress-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('.codex-tmp/ai-settings-ui')
      ..createSync(recursive: true);
    await File(
      '${directory.path}/$name',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<_Launch> _open(WidgetTester tester, _Driver driver) async {
  final launch = _Launch();
  await tester.pumpWidget(
    _app(
      Builder(
        builder: (context) => TextButton(
          onPressed: () {
            launch.result = showAiProgressDialog(
              context,
              title: '正在识别客户文件',
              subtitle: 'UJ23 quotation.xlsx',
              stages: _stages,
              task: driver.call,
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
  // 帧后启动作业。
  await tester.pump();
  return launch;
}

Finder _stageRow(int index) => find.byKey(ValueKey('ai-progress-stage-$index'));

Finder _doneIn(int index) => find.descendant(
  of: _stageRow(index),
  matching: find.byIcon(Icons.check_rounded),
);

Finder _spinnerIn(int index) => find.descendant(
  of: _stageRow(index),
  matching: find.byType(CircularProgressIndicator),
);

void main() {
  setUpAll(() async {
    final loader = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await loader.load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets(
    'shows title, stages and elapsed time, advances stages and returns the result',
    (tester) async {
      final driver = _Driver();
      final launch = await _open(tester, driver);

      expect(find.text('正在识别客户文件'), findsOneWidget);
      expect(find.text('UJ23 quotation.xlsx'), findsOneWidget);
      for (final stage in _stages) {
        expect(find.text(stage.label), findsOneWidget);
      }
      expect(find.text(_zh.aiJobElapsed('0:00')), findsOneWidget);
      expect(find.text(_zh.aiJobCancel), findsOneWidget);
      expect(driver.progress, isNotNull);

      driver.progress!(_snap(id: '', stage: AiJobSnapshot.uploadingStage));
      await tester.pump();
      expect(_spinnerIn(0), findsOneWidget);
      expect(_doneIn(0), findsNothing);

      // 拿到作业 id = 上传完成; 服务端还在排队。
      driver.progress!(_snap(status: AiJobStatus.pending));
      await tester.pump();
      expect(_doneIn(0), findsOneWidget);
      expect(_spinnerIn(1), findsOneWidget);
      expect(find.text(_zh.aiJobQueued), findsOneWidget);

      driver.progress!(_snap(stage: 'AI_LAYOUT'));
      await tester.pump(const Duration(seconds: 3));
      expect(_doneIn(1), findsOneWidget);
      expect(_spinnerIn(2), findsOneWidget);
      expect(find.text(_zh.aiJobQueued), findsNothing);
      expect(find.text(_zh.aiJobElapsed('0:03')), findsOneWidget);
      await _capture(tester, 'progress-dialog-light.png');

      // 阶段只进不退, 未登记的阶段键保持当前一步。
      driver.progress!(_snap(stage: 'READING'));
      driver.progress!(_snap(stage: 'SOMETHING_NEW'));
      await tester.pump();
      expect(_spinnerIn(2), findsOneWidget);

      final done = _snap(
        status: AiJobStatus.succeeded,
        stage: 'DONE',
        result: const {'schemaVersion': 2},
      );
      driver.completer.complete(done);
      await tester.pumpAndSettle();

      expect(find.text('正在识别客户文件'), findsNothing);
      expect(await launch.result, same(done));
    },
  );

  testWidgets('long waits show a reassurance line', (tester) async {
    final driver = _Driver();
    await _open(tester, driver);
    driver.progress!(_snap(stage: 'READING'));
    await tester.pump(const Duration(seconds: 29));
    expect(find.text(_zh.aiJobSlowHint), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text(_zh.aiJobSlowHint), findsOneWidget);
    driver.completer.complete(_snap(status: AiJobStatus.succeeded));
    await tester.pumpAndSettle();
  });

  testWidgets('cancel closes at once, returns null and signals the job', (
    tester,
  ) async {
    final driver = _Driver();
    final launch = await _open(tester, driver);

    // 适老化触控基线: 取消按钮至少 48 高。
    expect(
      tester.getSize(find.byKey(const ValueKey('ai-progress-cancel'))).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.byKey(const ValueKey('ai-progress-cancel')));
    await tester.pumpAndSettle();

    expect(find.text('正在识别客户文件'), findsNothing);
    expect(await launch.result, isNull);
    expect(driver.token!.isCancelled, isTrue);
    // 作业随后以「已取消」结束也不会再弹任何东西。
    driver.completer.completeError(
      const AiJobFailure(message: 'x', code: AiJobFailure.codeCancelled),
    );
    await tester.pumpAndSettle();
    expect(launch.error, isNull);
  });

  testWidgets('system back cancels instead of leaving the job orphaned', (
    tester,
  ) async {
    final driver = _Driver();
    final launch = await _open(tester, driver);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(await launch.result, isNull);
    expect(driver.token!.isCancelled, isTrue);
  });

  testWidgets('a failed job closes the dialog and throws its plain reason', (
    tester,
  ) async {
    final driver = _Driver();
    final launch = await _open(tester, driver);

    driver.completer.completeError(
      const AiJobFailure(message: '文件无法解析', code: 'FILE_UNREADABLE'),
    );
    await tester.pumpAndSettle();

    expect(find.text('正在识别客户文件'), findsNothing);
    expect(
      launch.error,
      isA<AiJobFailure>().having((f) => f.message, 'message', '文件无法解析'),
    );
  });

  testWidgets('client-side timeouts are shown in the current language', (
    tester,
  ) async {
    final driver = _Driver();
    final launch = await _open(tester, driver);

    driver.completer.completeError(
      const AiJobFailure(message: 'raw', code: AiJobFailure.codeClientTimeout),
    );
    await tester.pumpAndSettle();

    expect(
      launch.error,
      isA<AiJobFailure>()
          .having((f) => f.message, 'message', _zh.aiJobTimeout)
          .having((f) => f.code, 'code', AiJobFailure.codeClientTimeout),
    );
  });

  testWidgets('a failure without a server reason is shown in the current '
      'language and keeps the server code', (tester) async {
    final driver = _Driver();
    final launch = await _open(tester, driver);

    driver.completer.completeError(
      const AiJobFailure(
        message: 'fallback',
        code: 'AI_UNAVAILABLE',
        clientMessage: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      launch.error,
      isA<AiJobFailure>()
          .having((f) => f.message, 'message', _zh.aiJobFailedGeneric)
          .having((f) => f.code, 'code', 'AI_UNAVAILABLE'),
    );
  });

  testWidgets(
    'a job that ends under another dialog closes only its own dialog',
    (tester) async {
      final driver = _Driver();
      final launch = await _open(tester, driver);

      // 作业进行中, 上面又弹出一个根导航上的框(如会话过期后的重新登录框)。
      unawaited(
        showDialog<void>(
          context: tester.element(find.text('正在识别客户文件')),
          builder: (_) => const AlertDialog(content: Text('请重新登录')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('请重新登录'), findsOneWidget);

      final done = _snap(status: AiJobStatus.succeeded, stage: 'DONE');
      driver.completer.complete(done);
      await tester.pump();
      await tester.pumpAndSettle();

      // 关掉的是进度弹窗自己, 上面的框原样留着, 结果照样交回。
      expect(find.text('正在识别客户文件'), findsNothing);
      expect(find.text('请重新登录'), findsOneWidget);
      expect(await launch.result, same(done));
      expect(launch.error, isNull);
    },
  );

  testWidgets('a rejected submit reaches the caller as the ApiException', (
    tester,
  ) async {
    final driver = _Driver();
    final launch = await _open(tester, driver);

    driver.completer.completeError(
      ApiException('RATE_LIMITED', '你已有识别任务在进行, 请稍等', httpStatus: 429),
    );
    await tester.pumpAndSettle();

    expect(
      launch.error,
      isA<ApiException>().having((e) => e.httpStatus, 'status', 429),
    );
  });

  testWidgets('runAiJob drives the real runner inside the dialog', (
    tester,
  ) async {
    final repository = _InstantRepository();
    final runner = AiJobRunner(repository, sleep: (_) async {});
    Future<AiJobSnapshot?>? result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => result = runAiJob(
              context,
              runner: runner,
              request: const AiJobRequest(
                kind: 'SALES_DOCUMENT_INTAKE',
                params: {},
                bytes: [1],
                fileName: 'a.xlsx',
                contentType: 'application/octet-stream',
              ),
              title: '正在识别客户文件',
              stages: _stages,
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    final snapshot = await result;
    expect(snapshot?.status, AiJobStatus.succeeded);
    expect(snapshot?.result, {'lines': 3});
    expect(repository.submitted, 1);
  });

  group('AiSparkleBadge motion', () {
    for (final (tier, animates) in [
      (PerformanceTier.standard, true),
      (PerformanceTier.lite, false),
    ]) {
      testWidgets(
        '${tier.name} tier ${animates ? 'breathes' : 'stays still'}',
        (tester) async {
          await tester.pumpWidget(
            _app(
              const AiSparkleBadge(),
              overrides: [
                performanceProvider.overrideWith(() => _FixedTier(tier)),
              ],
            ),
          );
          expect(tester.hasRunningAnimations, animates);
        },
      );
    }

    testWidgets('system reduced motion stops the loop', (tester) async {
      await tester.pumpWidget(
        _app(
          const MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: AiSparkleBadge(),
          ),
          overrides: [
            performanceProvider.overrideWith(
              () => _FixedTier(PerformanceTier.rich),
            ),
          ],
        ),
      );
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('works before preferences are injected', (tester) async {
      // 未注入 sharedPreferences 时按标准档处理, 不报错。
      await tester.pumpWidget(_app(const AiSparkleBadge()));
      expect(tester.takeException(), isNull);
      expect(tester.hasRunningAnimations, isTrue);
    });
  });
}

class _FixedTier extends PerformanceNotifier {
  _FixedTier(this.tier);

  final PerformanceTier tier;

  @override
  PerformanceTier build() => tier;
}

class _InstantRepository implements AiJobRepository {
  int submitted = 0;

  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) async {
    submitted++;
    return _snap(status: AiJobStatus.pending);
  }

  @override
  Future<AiJobSnapshot> get(String jobId) async => _snap(
    status: AiJobStatus.succeeded,
    stage: 'DONE',
    result: const {'lines': 3},
  );

  @override
  Future<void> cancel(String jobId) async {}
}
