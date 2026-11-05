import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/business_precision_coordinator.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/export/report_export_job_dialog.dart';
import 'package:uten_imp/shared/export/report_export_jobs.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/widgets/business_precision_dialog.dart';

final _permissions = StateProvider<Set<String>>((_) => {'finance_report:view'});

class _Api extends ApiClient {
  _Api() : super(Dio(BaseOptions(baseUrl: 'https://export-wait.test/api')));
  final creates = <Map<String, dynamic>>[],
      precisions = <Map<String, dynamic>>[];
  final reads = <String>[],
      cancels = <String>[],
      receipts = <String>[],
      downloads = <String>[];
  List<Map<String, dynamic>> history = [];
  Completer<void>? createGate,
      readGate,
      cancelGate,
      precisionGate,
      receiptGate,
      downloadGate;
  bool loseCreate = false, losePrecision = false, precisionAccepted = false;
  String status = 'SUCCEEDED';
  Map<String, dynamic> job(String id) => {
    'id': id,
    'domain': 'finance',
    'report': 'gl/balance-sheet',
    'format': 'xlsx',
    'status': status,
    'rows': 53,
    'attempt': precisionAccepted ? 2 : 1,
    'snapshotAt': '2026-01-31T00:00:00Z',
    if (status == 'WAITING_PRECISION')
      'precisionRequirement': {
        'calculationKey': 'ratio',
        'groupKey': 'ratio',
        'label': '本次原报表比率',
        'maxScale': 30,
        'reason': 'NON_TERMINATING',
        'notWritten': true,
      },
    'precisionChoices': precisionAccepted
        ? {
            'ratio': {'scale': 4, 'rounding': 'DOWN'},
          }
        : <String, dynamic>{},
  };
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => history;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/download-authorization')) return {'authorized': true};
    if (path.contains('/precision-receipts/')) {
      receipts.add(path);
      final gate = receiptGate;
      receiptGate = null;
      if (gate != null) await gate.future;
      return {
        'found': precisionAccepted,
        if (precisionAccepted) 'job': job(path.split('/')[2]),
      };
    }
    reads.add(path);
    final gate = readGate;
    readGate = null;
    if (gate != null) await gate.future;
    return job(path.split('/').last);
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/cancel')) {
      cancels.add(path);
      final gate = cancelGate;
      cancelGate = null;
      if (gate != null) await gate.future;
      status = 'CANCELLED';
      return {};
    }
    final command = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(body)) as Map,
    );
    if (path.endsWith('/precision')) {
      precisions.add(command);
      final gate = precisionGate;
      precisionGate = null;
      if (gate != null) await gate.future;
      precisionAccepted = true;
      status = 'SUCCEEDED';
      if (losePrecision) throw NetworkTimeoutException();
      return job(path.split('/')[2]);
    }
    creates.add(command);
    final gate = createGate;
    createGate = null;
    if (gate != null) await gate.future;
    if (loseCreate) {
      loseCreate = false;
      throw NetworkTimeoutException();
    }
    return job(command['id'] as String);
  }

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    downloads.add(path);
    final gate = downloadGate;
    downloadGate = null;
    if (gate != null) await gate.future;
    return Uint8List.fromList([1, 2, 3]);
  }
}

Future<void> _frames(WidgetTester tester, [int count = 10]) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

class _Environment {
  _Environment(this.container, this.client, this.request, this.store);
  final ProviderContainer container;
  final ReportExportJobsClient client;
  final ReportExportJobRequest request;
  final ReportExportPendingStore store;
  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
  }
}

Future<_Environment> _open(
  WidgetTester tester,
  _Api api, {
  ReportExportJobsClient? client,
  ReportExportJobRequest? request,
  ReportExportPendingStore? store,
  ValueNotifier<int>? rebuild,
  Size? size,
  double textScale = 1,
  bool dark = false,
}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  final preferences = await SharedPreferences.getInstance();
  final c =
      client ??
      ReportExportJobsClient(
        api,
        await api.captureRequestScope(isCurrent: () => true),
      );
  final q =
      request ??
      ReportExportJobRequest.create(
        domain: 'finance',
        report: 'gl/balance-sheet',
        parameters: {'dateFrom': '2026-01-01', 'dateTo': '2026-01-31'},
      );
  final s =
      store ??
      ReportExportPendingStore(
        preferences,
        c.scope.identity,
        'finance',
        'gl/balance-sheet',
      );
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      apiBaseUrlProvider.overrideWithValue(api.baseUrl),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(
          userId: '00000000-0000-0000-0000-000000000901',
        ),
      ),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
    ],
  );
  bool current() =>
      container.read(_permissions).contains('finance_report:view');
  Widget dialog() => ReportExportJobDialog(
    client: c,
    request: q,
    store: rebuild == null
        ? s
        : ReportExportPendingStore(
            preferences,
            c.scope.identity,
            'finance',
            'gl/balance-sheet',
          ),
    stillCurrent: current,
    onDownload: (job) async {
      await c.download(job.id, '');
    },
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: dark ? buildDarkTheme() : buildLightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => rebuild == null
                    ? dialog()
                    : ValueListenableBuilder<int>(
                        valueListenable: rebuild,
                        builder: (_, _, _) => dialog(),
                      ),
              ),
              child: const Text('打开导出任务'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开导出任务'));
  await _frames(tester);
  return _Environment(container, c, q, s);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UtenBusyOverlay.debugResetYield();
  });
  tearDown(UtenBusyOverlay.debugResetYield);

  testWidgets(
    'initial create and every ordinary task button own one real wait mask with guarded reentry',
    (tester) async {
      final api = _Api()..status = 'RUNNING';
      final create = api.createGate = Completer<void>();
      final env = await _open(tester, api);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(api.creates, hasLength(1));
      expect(env.store.read()?.id, env.request.id);
      create.complete();
      await _frames(tester);
      final read = api.readGate = Completer<void>();
      final point = tester.getCenter(find.text('核查任务'));
      await tester.tapAt(point);
      await _frames(tester);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(api.reads, hasLength(1));
      await tester.tapAt(point);
      await _frames(tester, 2);
      expect(api.reads, hasLength(1));
      read.complete();
      await _frames(tester);
      final cancel = api.cancelGate = Completer<void>();
      await tester.tap(find.text('取消任务'));
      await _frames(tester);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(api.cancels, hasLength(1));
      cancel.complete();
      await _frames(tester);
      expect(find.text('已取消'), findsOneWidget);
      final next = api.createGate = Completer<void>();
      await tester.tap(find.text('按当前筛选新建'));
      await _frames(tester);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(api.creates, hasLength(2));
      expect(api.creates.last['id'], isNot(env.request.id));
      api.status = 'SUCCEEDED';
      next.complete();
      await _frames(tester);
      final download = api.downloadGate = Completer<void>();
      await tester.tap(find.text('下载文件'));
      await _frames(tester);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(api.downloads, hasLength(1));
      download.complete();
      await tester.pumpAndSettle();
      expect(find.byType(ReportExportJobDialog), findsNothing);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );

  testWidgets(
    'automatic polling remains nonblocking while the held request is still sequential',
    (tester) async {
      final api = _Api()..status = 'RUNNING';
      final env = await _open(tester, api);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      final read = api.readGate = Completer<void>();
      await tester.pump(const Duration(seconds: 1));
      await _frames(tester, 2);
      expect(api.reads, hasLength(1));
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(api.reads, hasLength(1));
      api.status = 'SUCCEEDED';
      read.complete();
      await tester.pumpAndSettle();
      expect(find.text('已生成'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );

  testWidgets(
    'unknown create retry keeps its original id and later restore only reads that pending task',
    (tester) async {
      final api = _Api()..loseCreate = true;
      var env = await _open(tester, api);
      expect(find.text('上次创建结果尚未确认'), findsOneWidget);
      final original = Map<String, dynamic>.from(api.creates.single);
      final retry = api.createGate = Completer<void>();
      api.loseCreate = true;
      await tester.tap(find.text('按原编号重试'));
      await _frames(tester);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(api.creates, hasLength(2));
      expect(api.creates.last, original);
      retry.complete();
      await _frames(tester);
      final client = env.client, request = env.request, store = env.store;
      await env.close(tester);
      final read = api.readGate = Completer<void>();
      env = await _open(
        tester,
        api,
        client: client,
        request: request,
        store: store,
      );
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(api.reads.single, endsWith('/${request.id}'));
      expect(api.creates, hasLength(2));
      read.complete();
      await tester.pumpAndSettle();
      expect(env.store.read(), isNull);
      expect(find.text('已生成'), findsOneWidget);
      await env.close(tester);
    },
  );

  testWidgets(
    'read withdrawal retires the mask and late success cannot clear the persisted original',
    (tester) async {
      final api = _Api();
      final create = api.createGate = Completer<void>();
      final env = await _open(tester, api);
      expect(env.store.read()?.id, env.request.id);
      env.container.read(_permissions.notifier).state = {};
      await _frames(tester);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      create.complete();
      await tester.pumpAndSettle();
      expect(env.store.read()?.id, env.request.id);
      expect(find.text('已生成'), findsNothing);
      expect(find.text('下载文件'), findsNothing);
      expect(api.creates, hasLength(1));
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );

  testWidgets(
    'a late old dialog completion cannot remove the replacement restoration wait',
    (tester) async {
      final api = _Api();
      final old = api.createGate = Completer<void>();
      var env = await _open(tester, api);
      final client = env.client, request = env.request, store = env.store;
      await env.close(tester);
      final read = api.readGate = Completer<void>();
      env = await _open(
        tester,
        api,
        client: client,
        request: request,
        store: store,
      );
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      old.complete();
      await _frames(tester);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(store.read()?.id, request.id);
      expect(api.creates, hasLength(1));
      read.complete();
      await tester.pumpAndSettle();
      expect(store.read(), isNull);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );

  testWidgets(
    'same-scope rebuild keeps the in-flight task and semantic store instead of retiring it',
    (tester) async {
      final rebuild = ValueNotifier(0);
      addTearDown(rebuild.dispose);
      final api = _Api();
      final create = api.createGate = Completer<void>();
      final env = await _open(tester, api, rebuild: rebuild);
      rebuild.value++;
      await _frames(tester);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      create.complete();
      await tester.pumpAndSettle();
      expect(find.text('已生成'), findsOneWidget);
      expect(find.textContaining('账号、权限或服务器已变化'), findsNothing);
      expect(api.creates, hasLength(1));
      await env.close(tester);
    },
  );

  testWidgets(
    'recent-task selection waits without creating a replacement job',
    (tester) async {
      final api = _Api();
      api.history = [api.job('00000000-0000-0000-0000-000000000902')];
      final env = await _open(tester, api);
      final read = api.readGate = Completer<void>();
      await tester.tap(find.byType(ListTile));
      await _frames(tester);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(api.creates, isEmpty);
      read.complete();
      await tester.pumpAndSettle();
      expect(find.text('已处理 53 行'), findsOneWidget);
      await env.close(tester);
    },
  );

  testWidgets(
    'real precision selection yields, lost DOWN retry preserves its nonce and receipt verification waits',
    (tester) async {
      final api = _Api()
        ..status = 'WAITING_PRECISION'
        ..losePrecision = true;
      final env = await _open(tester, api);
      var prompts = 0;
      final release = BusinessPrecisionCoordinator.instance.register((
        required,
      ) {
        prompts++;
        return showBusinessPrecisionDialog(
          tester.element(find.byType(ReportExportJobDialog)),
          required,
        );
      });
      addTearDown(release);
      await tester.tap(find.text('选择精度并继续原任务'));
      await _frames(tester);
      expect(find.byType(BusinessPrecisionDialog), findsOneWidget);
      expect(find.byType(UtenBusyOverlayCard), findsNothing);
      final input = find.byWidgetPredicate(
        (w) => w is UtenInput && w.label == '保留小数位数',
      );
      await tester.enterText(
        find.descendant(of: input, matching: find.byType(TextField)),
        '4',
      );
      await tester.tap(find.text('处理方式'));
      await _frames(tester);
      await tester.tap(find.text('直接截取，不进位').last);
      await _frames(tester);
      final precision = api.precisionGate = Completer<void>();
      await tester.tap(find.text('确认本次精度'));
      await _frames(tester);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      final original = Map<String, dynamic>.from(api.precisions.single);
      final frozen = env.store.readPrecisionResume()!;
      expect(frozen.choices['ratio']?.rounding, 'DOWN');
      expect(frozen.choices['ratio']?.scale, 4);
      precision.complete();
      await _frames(tester);
      final retry = api.precisionGate = Completer<void>();
      await tester.tap(find.text('重试原精度请求'));
      await _frames(tester);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(api.precisions.last, original);
      expect(env.store.readPrecisionResume()?.requestId, frozen.requestId);
      retry.complete();
      await _frames(tester);
      final receipt = api.receiptGate = Completer<void>();
      await tester.tap(find.text('核查任务'));
      await _frames(tester);
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      expect(api.receipts, hasLength(1));
      receipt.complete();
      await tester.pumpAndSettle();
      expect(prompts, 1);
      expect(api.precisions, hasLength(2));
      expect(env.store.readPrecisionResume(), isNull);
      expect(find.text('已生成'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await env.close(tester);
    },
  );

  for (final scenario in [
    (size: const Size(1280, 900), scale: 1.0, dark: false),
    (size: const Size(390, 640), scale: 1.5, dark: true),
    (size: const Size(360, 320), scale: 1.5, dark: false),
  ]) {
    testWidgets('real job and waiting surface fit $scenario', (tester) async {
      final api = _Api();
      final create = api.createGate = Completer<void>();
      final env = await _open(
        tester,
        api,
        size: scenario.size,
        textScale: scenario.scale,
        dark: scenario.dark,
      );
      expect(find.byType(UtenBusyOverlayCard), findsOneWidget);
      final wait = tester.getRect(find.byType(UtenBusyOverlayCard));
      expect(wait.left, greaterThanOrEqualTo(0));
      expect(wait.right, lessThanOrEqualTo(scenario.size.width));
      expect(wait.top, greaterThanOrEqualTo(0));
      expect(wait.bottom, lessThanOrEqualTo(scenario.size.height));
      create.complete();
      await tester.pumpAndSettle();
      expect(find.text('报表导出任务'), findsOneWidget);
      expect(find.text('已处理 53 行'), findsOneWidget);
      expect(find.text('下载文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await env.close(tester);
    });
  }
}
