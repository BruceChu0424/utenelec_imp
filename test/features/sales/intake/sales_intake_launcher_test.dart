// 识别入口流程: 选文件 → (PDF/图片先看 AI 是否可用并确认整份发送) → 进度弹窗 → 核对面板 →
// 补丁; 失败提示、改为新建报价单、恢复已有作业。作业执行器/进度弹窗/文件选择器用替身。
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_launcher.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/shared/ai/ai_job_models.dart';
import 'package:uten_imp/shared/ai/ai_job_runner.dart';
import 'package:uten_imp/shared/ai/ai_status_provider.dart';

import 'sales_intake_fixture.dart';
import 'sales_intake_test_support.dart';

class _Env {
  _Env(this.runner, this.presenter);

  final FakeAiJobRunner runner;
  final FakeProgressPresenter presenter;
  SalesIntakeLaunchResult? result;
  bool done = false;
}

Future<_Env> _pump(
  WidgetTester tester, {
  PlatformFile? file,
  FakeAiJobRunner? runner,
  AiStatus status = AiStatus.unavailable,
  SalesDocType docType = SalesDocType.order,
  String? resumeJobId,
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  FilePicker.platform = FakeFilePicker(file);
  final env = _Env(
    runner ?? FakeAiJobRunner(result: intakeResultJson()),
    FakeProgressPresenter(),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        aiJobRunnerProvider.overrideWithValue(env.runner),
        salesIntakeProgressPresenterProvider.overrideWithValue(
          presenterOf(env.presenter),
        ),
        aiStatusProvider.overrideWith((ref) async => status),
      ],
      child: MaterialApp(
        theme: buildLightTheme(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => Stack(
          children: [
            Positioned.fill(child: child!),
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AppNotificationHost(),
            ),
          ],
        ),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Center(
              child: TextButton(
                onPressed: () async {
                  env.result = resumeJobId == null
                      ? await launchSalesIntake(
                          context,
                          ref,
                          docType: docType,
                          clientId: 'client-sunas',
                          clientName: '尼日利亚SUNAS',
                          canHandoffToQuote: true,
                        )
                      : await resumeSalesIntake(
                          context,
                          ref,
                          docType: docType,
                          jobId: resumeJobId,
                        );
                  env.done = true;
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  return env;
}

Future<void> _importAll(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('sales-intake-import-all')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Excel: 直接识别(不问 AI), 进度分步, 全部导入得到补丁与原文件', (tester) async {
    final env = await _pump(tester, file: fakeFile('UJ23 quotation.xlsx'));
    final request = env.runner.lastRequest!;
    expect(request.kind, 'SALES_DOCUMENT_INTAKE');
    expect(request.params, {'docType': 'order', 'clientId': 'client-sunas'});
    expect(
      request.contentType,
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    expect(request.fileName, 'UJ23 quotation.xlsx');
    expect(env.presenter.title, '正在识别客户文件');
    expect(env.presenter.stages!.map((s) => s.label), [
      '上传文件',
      '读取表格',
      '识别表头与列',
      '匹配货品',
      '匹配客户',
      '计算折扣',
    ]);
    expect(
      env.presenter.stages![2].serverStages,
      containsAll(<String>['LAYOUT', 'EXTRACTING']),
    );
    expect(find.text('核对识别结果'), findsOneWidget);

    await _importAll(tester);
    expect(env.done, isTrue);
    final patch = env.result!.patch!;
    expect(patch.jobId, 'job-42');
    expect(patch.rows, hasLength(4));
    expect(env.result!.file!.name, 'UJ23 quotation.xlsx');
    expect(env.result!.handoffJobId, isNull);
  });

  testWidgets('PDF 且 AI 没开: 直接提示, 不上传', (tester) async {
    final env = await _pump(tester, file: fakeFile('pi.pdf'));
    expect(env.runner.lastRequest, isNull);
    expect(find.text('PDF/图片需要开启 AI 才能识别, 请上传 Excel 或联系管理员'), findsOneWidget);
    expect(env.result, isNull);
  });

  testWidgets('图片但模型不支持看图: 直接提示', (tester) async {
    final env = await _pump(
      tester,
      file: fakeFile('pi.jpg'),
      status: const AiStatus(
        available: true,
        aiAllowedForMe: true,
        supportsVision: false,
      ),
    );
    expect(env.runner.lastRequest, isNull);
    expect(find.text('这是图片格式的文件, 需要管理员在 AI 服务设置中启用支持图片识别的模型'), findsOneWidget);
  });

  testWidgets('PDF 且 AI 可用: 先确认整份文件会发给 AI, 取消就不上传', (tester) async {
    final env = await _pump(
      tester,
      file: fakeFile('pi.pdf'),
      status: const AiStatus(
        available: true,
        aiAllowedForMe: true,
        supportsVision: true,
      ),
    );
    expect(find.text('整份文件会发送给 AI 服务识别'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(env.runner.lastRequest, isNull);
    expect(env.done, isTrue);
    expect(env.result, isNull);
  });

  testWidgets('PDF 确认后照常识别', (tester) async {
    final env = await _pump(
      tester,
      file: fakeFile('pi.pdf'),
      status: const AiStatus(
        available: true,
        aiAllowedForMe: true,
        supportsVision: true,
      ),
    );
    await tester.tap(find.text('继续识别'));
    await tester.pumpAndSettle();
    expect(env.runner.lastRequest!.contentType, 'application/pdf');
    expect(find.text('核对识别结果'), findsOneWidget);
  });

  testWidgets('不支持的类型 / 过大的文件: 提示, 不上传', (tester) async {
    var env = await _pump(tester, file: fakeFile('notes.docx'));
    expect(find.text('只能识别 Excel、CSV、PDF 或图片文件'), findsOneWidget);
    expect(env.runner.lastRequest, isNull);

    env = await _pump(
      tester,
      file: fakeFile('huge.xlsx', size: kSalesIntakeMaxFileBytes + 1),
    );
    expect(find.text('文件太大, 最大 15MB'), findsOneWidget);
    expect(env.runner.lastRequest, isNull);
  });

  testWidgets('作业失败: 用服务端的大白话提示, 不打开面板', (tester) async {
    final env = await _pump(
      tester,
      file: fakeFile('a.xlsx'),
      runner: FakeAiJobRunner(
        failure: const AiJobFailure(message: '文件无法解析', code: 'FILE_UNREADABLE'),
      ),
    );
    expect(find.text('文件无法解析'), findsOneWidget);
    expect(find.text('核对识别结果'), findsNothing);
    expect(env.result, isNull);
  });

  testWidgets('识别结果里没有明细: 提示后结束', (tester) async {
    final json = intakeResultJson()..['lines'] = <Object>[];
    await _pump(
      tester,
      file: fakeFile('a.xlsx'),
      runner: FakeAiJobRunner(result: json),
    );
    expect(find.text('文件里没找到货品明细, 请确认上传的是报价单或形式发票'), findsOneWidget);
    expect(find.text('核对识别结果'), findsNothing);
  });

  testWidgets('订货单没标价 →「改为新建报价单」返回作业 id', (tester) async {
    final env = await _pump(tester, file: fakeFile('a.xlsx'));
    final handoff = find.byKey(const ValueKey('sales-intake-handoff-quote'));
    await tester.ensureVisible(handoff);
    await tester.pumpAndSettle();
    await tester.tap(handoff);
    await tester.pumpAndSettle();
    expect(env.result!.handoffJobId, 'job-42');
    expect(env.result!.patch, isNull);
  });

  testWidgets('恢复已有作业: 不选文件不上传, 按报价单规则导入', (tester) async {
    final env = await _pump(
      tester,
      docType: SalesDocType.quote,
      resumeJobId: 'job-7',
    );
    expect(env.runner.resumedJobId, 'job-7');
    expect(env.runner.lastRequest, isNull);
    await _importAll(tester);
    final patch = env.result!.patch!;
    // 报价单: 没标价的货品也导入(待财务定价)。
    expect(patch.rows.map((r) => r.intakeLineKey), contains('S1R12'));
    expect(env.result!.file, isNull);
  });

  testWidgets('非成功终态快照(不抛异常)也按失败提示', (tester) async {
    final env = await _pump(
      tester,
      file: fakeFile('a.xlsx'),
      runner: FakeAiJobRunner(
        terminal: const AiJobSnapshot(
          id: 'x',
          kind: 'SALES_DOCUMENT_INTAKE',
          status: AiJobStatus.failed,
          errorMessage: '账号权限已变化, 请重新识别',
        ),
      ),
    );
    expect(find.text('账号权限已变化, 请重新识别'), findsOneWidget);
    expect(find.text('核对识别结果'), findsNothing);
    expect(env.result, isNull);
  });
}
