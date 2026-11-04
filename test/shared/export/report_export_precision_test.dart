import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/business_precision.dart';
import 'package:uten_imp/core/network/business_precision_coordinator.dart';
import 'package:uten_imp/shared/export/report_export_jobs.dart';
import 'package:uten_imp/shared/export/report_export_job_dialog.dart';

void main() {
  test(
    'same export can replace only an explicitly rejected current choice',
    () {
      final job = ReportExportJob.fromJson({
        'id': '00000000-0000-4000-8000-000000000001',
        'domain': 'sales',
        'report': 'order/detail',
        'format': 'xlsx',
        'status': 'WAITING_PRECISION',
        'attempt': 2,
        'precisionChoices': {
          'ratio': {'scale': 4, 'rounding': 'DOWN'},
          'other': {'scale': 8, 'rounding': 'HALF_UP'},
        },
        'precisionRequirement': {
          'calculationKey': 'ratio',
          'label': '本次来源分摊',
          'groupKey': 'ratio',
          'maxScale': 24,
          'reason': 'PRECISION_LIMIT',
          'notWritten': true,
          'selectionRejected': true,
        },
      });
      final request = ReportExportPrecisionResume.create(
        job,
        const BusinessPrecisionChoice(5, 'DOWN'),
      );
      expect(request.jobId, job.id);
      expect(request.expectedAttempt, 2);
      expect(request.choices['ratio']!.scale, 5);
      expect(request.choices['other']!.scale, 8);
    },
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'waiting job resumes same identity and a lost acknowledgement resolves from its own nonce',
    (tester) async {
      final api = _Api()..acceptBeforeLoss = true;
      int prompts = 0;
      final unregister = BusinessPrecisionCoordinator.instance.register((
        _,
      ) async {
        prompts++;
        return const BusinessPrecisionChoice(3, 'DOWN');
      });
      addTearDown(unregister);
      final mounted = await _mount(tester, api);
      await tester.tap(find.text('选择精度并继续原任务'));
      await tester.pumpAndSettle();
      expect(api.resumes, hasLength(1));
      final saved = mounted.store.readPrecisionResume();
      expect(saved, isNotNull);
      expect(saved!.jobId, mounted.request.id);
      expect(saved.expectedAttempt, 1);
      expect(find.text('重试原精度请求'), findsOneWidget);
      expect(find.text('选择精度并继续原任务'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      api.status = 'SUCCEEDED';
      await _mount(
        tester,
        api,
        store: mounted.store,
        request: ReportExportJobRequest.create(
          domain: 'sales',
          report: 'order/detail',
          parameters: {'dateFrom': 'a-different-current-filter'},
        ),
      );
      expect(prompts, 1);
      expect(api.resumes, hasLength(1));
      expect(api.creates, hasLength(1));
      expect(mounted.store.readPrecisionResume(), isNull);
      expect(find.text('下载文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unresolved precision command retains exact body and header instead of asking again',
    (tester) async {
      final api = _Api();
      int prompts = 0;
      final unregister = BusinessPrecisionCoordinator.instance.register((
        _,
      ) async {
        prompts++;
        return const BusinessPrecisionChoice(4, 'HALF_UP');
      });
      addTearDown(unregister);
      final mounted = await _mount(tester, api);
      await tester.tap(find.text('选择精度并继续原任务'));
      await tester.pumpAndSettle();
      final before = jsonEncode(api.resumes.single),
          header = api.headers.single;
      await tester.pumpWidget(const SizedBox());
      await _mount(tester, api, store: mounted.store, request: mounted.request);
      expect(find.text('重试原精度请求'), findsOneWidget);
      await tester.tap(find.text('重试原精度请求'));
      await tester.pumpAndSettle();
      expect(prompts, 1);
      expect(api.resumes, hasLength(2));
      expect(jsonEncode(api.resumes.last), before);
      expect(api.headers.last, header);
      expect(api.creates, hasLength(1));
      expect(mounted.store.readPrecisionResume(), isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'waiting precision is cancellable before any policy is selected',
    (tester) async {
      final api = _Api();
      final mounted = await _mount(tester, api);
      expect(find.textContaining('尚未生成可下载文件'), findsOneWidget);
      await tester.tap(find.text('取消任务'));
      await tester.pumpAndSettle();
      expect(api.status, 'CANCELLED');
      expect(api.resumes, isEmpty);
      expect(mounted.store.readPrecisionResume(), isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('retired reader cannot publish a queued precision selection', (
    tester,
  ) async {
    final api = _Api();
    final choice = Completer<BusinessPrecisionChoice?>();
    final unregister = BusinessPrecisionCoordinator.instance.register(
      (_) => choice.future,
    );
    addTearDown(unregister);
    bool current = true;
    final mounted = await _mount(tester, api, current: () => current);
    await tester.tap(find.text('选择精度并继续原任务'));
    await tester.pump();
    current = false;
    choice.complete(const BusinessPrecisionChoice(2, 'DOWN'));
    await tester.pumpAndSettle();
    expect(api.resumes, isEmpty);
    expect(mounted.store.readPrecisionResume(), isNull);
    expect(tester.takeException(), isNull);
  });
}

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://export.test/api')));
  String status = 'WAITING_PRECISION';
  bool acceptBeforeLoss = false, accepted = false;
  String? id, nonce;
  final creates = <Map<String, dynamic>>[],
      resumes = <Map<String, dynamic>>[],
      headers = <String?>[];
  Map<String, dynamic> job() => {
    'id': id,
    'domain': 'sales',
    'report': 'order/detail',
    'format': 'xlsx',
    'status': status,
    'rows': 0,
    'attempt': status == 'SUCCEEDED' ? 2 : 1,
    'bytes': 0,
    if (status == 'WAITING_PRECISION')
      'precisionRequirement': {
        'calculationKey': 'ratio',
        'groupKey': 'ratio',
        'label': '本次原报表比率',
        'maxScale': 30,
        'reason': 'NON_TERMINATING',
        'notWritten': true,
      },
    if (status == 'WAITING_PRECISION') 'precisionChoices': <String, dynamic>{},
  };
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    if (path.endsWith('/cancel')) {
      status = 'CANCELLED';
      return {};
    }
    final command = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(body)) as Map,
    );
    if (path.endsWith('/precision')) {
      resumes.add(command);
      this.headers.add(BusinessPrecisionTransport.current?.encodedHeader);
      nonce = command['requestId'].toString();
      if (resumes.length == 1) {
        accepted = acceptBeforeLoss;
        throw NetworkTimeoutException();
      }
      accepted = true;
      status = 'SUCCEEDED';
      return job();
    }
    creates.add(command);
    id = command['id'].toString();
    return job();
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/precision-receipts/')) {
      return accepted && path.endsWith(nonce!)
          ? {'found': true, 'job': job()}
          : {'found': false};
    }
    return job();
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];
}

Future<({ReportExportPendingStore store, ReportExportJobRequest request})>
_mount(
  WidgetTester tester,
  _Api api, {
  ReportExportPendingStore? store,
  ReportExportJobRequest? request,
  bool Function()? current,
}) async {
  final scope = await api.captureRequestScope(isCurrent: current ?? () => true);
  final preferences = await SharedPreferences.getInstance();
  final original =
      request ??
      ReportExportJobRequest.create(
        domain: 'sales',
        report: 'order/detail',
        parameters: {'dateFrom': '2026-09-01'},
      );
  final retained =
      store ??
      ReportExportPendingStore(
        preferences,
        scope.identity,
        'sales',
        'order/detail',
      );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: Scaffold(
          body: ReportExportJobDialog(
            client: ReportExportJobsClient(api, scope),
            request: original,
            store: retained,
            stillCurrent: current ?? () => true,
            onDownload: (_) async {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (store: retained, request: original);
}
