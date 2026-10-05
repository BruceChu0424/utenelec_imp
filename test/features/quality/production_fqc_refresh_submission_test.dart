import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/quality/pages/production_fqc_handling_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../support/audit_screenshot_support.dart';

const _id = '10000000-0000-0000-0000-000000000001';
const _id3 = '10000000-0000-0000-0000-000000000003';
const _sheetId = '20000000-0000-0000-0000-000000000001';
final _scope = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'quality-user'),
);
final _server = StateProvider<String>((ref) => 'https://fqc-test.example/api');

typedef _Env = ({
  GoRouter router,
  ProviderContainer container,
  _MemoryStorage storage,
  bool sheet,
});

Future<_Env> _mount(
  WidgetTester tester,
  _FqcApi api, {
  bool sheet = false,
  _MemoryStorage? storage,
  String? initial,
  GlobalKey? boundary,
  Size size = const Size(1500, 1300),
  double textScale = 1,
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final store = storage ?? _MemoryStorage();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      currentPermissionsProvider.overrideWithValue({
        Perm.productionQualityInspectionView,
        Perm.productionQualityInspectionApprove,
      }),
      isSuperAdminProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWithValue(preferences),
      formDraftStorageProvider.overrideWithValue(store),
    ],
  );
  final router = GoRouter(
    initialLocation:
        initial ??
        (sheet
            ? RouteName.productionFqcSheetHandling(_sheetId)
            : RouteName.productionFqcInspectionHandling(_id)),
    routes: [
      GoRoute(
        path: '/other',
        builder: (_, _) => const Scaffold(body: Text('新页面')),
      ),
      DraftAwareGoRoute(
        path: '${RouteName.productionFqcSheetHandlingBase}/:sheetId',
        builder: const bool.fromEnvironment('UTEN_FQC_LEGACY_ROUTE_KEY')
            ? (_, state) => ProductionFqcSheetHandlingPage(
                sheetId: state.pathParameters['sheetId']!,
              )
            : ProductionFqcSheetHandlingPage.route,
      ),
      DraftAwareGoRoute(
        path: '${RouteName.productionFqcInspectionHandlingBase}/:inspectionId',
        builder: const bool.fromEnvironment('UTEN_FQC_LEGACY_ROUTE_KEY')
            ? (_, state) => ProductionFqcInspectionPage(
                inspectionId: state.pathParameters['inspectionId']!,
                extra: state.extra,
              )
            : ProductionFqcInspectionPage.route,
      ),
    ],
  );
  await tester.pumpWidget(
    _OwnedHarness(
      key: UniqueKey(),
      container: container,
      router: router,
      boundary: boundary,
      textScale: textScale,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 400));
  }
  return (router: router, container: container, storage: store, sheet: sheet);
}

class _OwnedHarness extends StatefulWidget {
  const _OwnedHarness({
    super.key,
    required this.container,
    required this.router,
    this.boundary,
    this.textScale = 1,
  });
  final ProviderContainer container;
  final GoRouter router;
  final GlobalKey? boundary;
  final double textScale;
  @override
  State<_OwnedHarness> createState() => _OwnedHarnessState();
}

class _OwnedHarnessState extends State<_OwnedHarness> {
  @override
  void dispose() {
    widget.router.dispose();
    widget.container.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: widget.boundary,
    child: UncontrolledProviderScope(
      container: widget.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: widget.boundary == null ? null : _screenshotTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(widget.textScale)),
          child: child!,
        ),
        routerConfig: widget.router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
}

ThemeData _screenshotTheme() {
  final theme = auditScreenshotTheme(buildLightTheme());
  return theme.copyWith(
    dialogTheme: theme.dialogTheme.copyWith(
      titleTextStyle: theme.textTheme.headlineSmall,
      contentTextStyle: theme.textTheme.bodyMedium,
    ),
  );
}

List<FqcReportRow> _rows(WidgetTester tester, {required bool sheet}) => tester
    .widget<MasterDataTableView<FqcReportRow>>(
      find.byKey(
        Key(sheet ? 'fqc-sheet-report-table' : 'fqc-inspection-decision-table'),
      ),
    )
    .items;

Future<void> _submit(
  WidgetTester tester, {
  required bool sheet,
  bool recovery = false,
  String? reason,
}) async {
  final button = find.byKey(
    Key(sheet ? 'fqc-sheet-submit-report' : 'fqc-inspection-submit-report'),
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
  if (reason != null) {
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      reason,
    );
  }
  // The fallback also runs the same regression against the exact former page.
  await tester.tap(
    recovery && find.text('继续原提交').evaluate().isNotEmpty
        ? find.text('继续原提交')
        : find.byKey(const Key('inspection-report-confirm-submit')),
  );
  await tester.pumpAndSettle();
}

Future<void> _startSubmit(WidgetTester tester, {required bool sheet}) async {
  final button = find.byKey(
    Key(sheet ? 'fqc-sheet-submit-report' : 'fqc-inspection-submit-report'),
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

class _MemoryStorage implements FormDraftStorage {
  final records = <String, String>{};
  bool failWrites = false;
  Future<void> Function(String value)? beforeWrite;
  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final e in records.entries)
      if (e.key.startsWith(prefix)) e.key: e.value,
  };
  @override
  Future<String?> read(String key) async => records[key];
  @override
  Future<void> write(String key, String value) async {
    records[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    records.remove(key);
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    if (value != null) await beforeWrite?.call(value);
    if (failWrites) throw StateError('storage full');
    if (records[key] != expectedValue) return false;
    if (value == null) {
      records.remove(key);
    } else {
      records[key] = value;
    }
    return true;
  }
}

class _FqcApi extends ApiClient {
  _FqcApi() : super(Dio());
  final List<String> ids = const [_id];
  final outcomes = <Object?>[];
  final calls = <({String id, Map<String, dynamic> body})>[];
  final events = <String, Map<String, dynamic>>{};
  final decisions = <String, Map<String, dynamic>>{};
  int commits = 0;
  int reads = 0;
  bool failReads = false;
  bool canDecide = true;
  bool preStocked = false;
  String? statusOverride;
  VoidCallback? beforePost;
  VoidCallback? afterPost;
  Future<void>? responseGate;
  final readGates = <String, Future<void>>{};
  Map<String, dynamic> inspection(String id) => {
    'id': id,
    'sourceReportId': 'report-$id',
    'sourceReportItemId': 'item-$id',
    'reportNo': 'RB-${ids.indexOf(id) + 1}',
    'goodsName': '测试货品',
    'reportedQty': 10,
    'passedQty': events.containsKey(id) ? events[id]!['passQty'] ?? 0 : 0,
    'failedQty': events.containsKey(id) ? events[id]!['failQty'] ?? 0 : 0,
    'remainingQty': events.containsKey(id)
        ? 10 -
              ((events[id]!['passQty'] as num?) ?? 0) -
              ((events[id]!['failQty'] as num?) ?? 0)
        : 10,
    'status':
        statusOverride ??
        (!events.containsKey(id)
            ? 'PENDING'
            : ((events[id]!['passQty'] as num) +
                          (events[id]!['failQty'] as num) >=
                      10
                  ? 'PASSED'
                  : 'PARTIAL')),
    if (preStocked)
      'preStocked': {
        'warehouseId': 'warehouse-1',
        'warehouseName': '成品仓',
        'place': 'A-01',
      },
    'authorizedInboundQty': 0,
    'createdAt': '2026-09-30T01:00:00Z',
    'updatedAt': '2026-09-30T01:00:00Z',
    'unitName': '个',
  };

  /// ADR-148：检查单办理页一行 = 一批实物；这里每份自成一批(批号 = 任务号)。
  Map<String, dynamic> lot(String id) {
    final row = inspection(id);
    return {
      'lotId': id,
      'sourceReportId': row['sourceReportId'],
      'reportNo': row['reportNo'],
      'goodsName': row['goodsName'],
      'unitName': row['unitName'],
      'reportedQty': row['reportedQty'],
      'passedQty': row['passedQty'],
      'failedQty': row['failedQty'],
      'remainingQty': row['remainingQty'],
      'status': row['status'],
      if (row['preStocked'] != null) 'preStocked': row['preStocked'],
      'members': [
        {
          'inspectionId': id,
          'sourceReportItemId': row['sourceReportItemId'],
          'sliceRank': 0,
          'kind': 'DEMAND',
          'reportedQty': row['reportedQty'],
          'passedQty': row['passedQty'],
          'failedQty': row['failedQty'],
          'remainingQty': row['remainingQty'],
          'status': row['status'],
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.productionQualityInspectionCapability) {
      return {'canDecide': canDecide};
    }
    if (path.startsWith('${ApiEndpoints.productionQualityInspectionSheets}/')) {
      reads++;
      if (failReads) throw NetworkException();
      final sheetId = path.split('/').last;
      await readGates[sheetId];
      final sheetRows = sheetId == _sheetId ? ids : [_id3];
      return {
        'sheet': {
          'id': sheetId,
          'sheetNo': 'FQC-1',
          'itemCount': sheetRows.length,
          'activeCount': sheetRows
              .where((id) => !events.containsKey(id))
              .length,
          'status': 'ACTIVE',
        },
        'inspections': [for (final id in sheetRows) inspection(id)],
        'lots': [for (final id in sheetRows) lot(id)],
      };
    }
    if (path.startsWith('${ApiEndpoints.productionQualityInspections}/')) {
      reads++;
      if (failReads) throw NetworkException();
      await readGates[path.split('/').last];
      return inspection(path.split('/').last);
    }
    return {'items': <Object>[], 'total': 0, 'totalPages': 0};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    expect(path.endsWith('/decisions'), isTrue);
    beforePost?.call();
    // 检查单页按批判定(/lots/{lotId}/decisions)；单份详情页仍逐份(/{id}/decisions)。
    final segments = path.split('/');
    final lotDecision = segments.contains('lots');
    final id = lotDecision
        ? segments[segments.indexOf('lots') + 1]
        : segments[3];
    final command = Map<String, dynamic>.from(body! as Map);
    calls.add((id: id, body: command));
    await responseGate;
    final outcome = outcomes.isEmpty ? null : outcomes.removeAt(0);
    if (outcome is Exception) {
      afterPost?.call();
      throw outcome;
    }
    final key = '$id/${command['idempotencyKey']}';
    final replay = decisions.containsKey(key);
    if (replay) {
      expect(command, decisions[key]);
    } else {
      decisions[key] = command;
      final previous = events[id];
      events[id] = {
        'passQty':
            ((previous?['passQty'] as num?) ?? 0) +
            ((command['passQty'] as num?) ?? 0),
        'failQty':
            ((previous?['failQty'] as num?) ?? 0) +
            ((command['failQty'] as num?) ?? 0),
      };
      commits++;
    }
    afterPost?.call();
    if (outcome == 'commit-timeout') throw NetworkTimeoutException();
    return lotDecision
        ? {'lotCommandId': 'decision-$id', 'lot': lot(id), 'replay': replay}
        : {
            'decisionEventId': 'decision-$id',
            'inspection': inspection(id),
            'replay': replay,
          };
  }
}

UtenAppBarActionButton _refreshButton(WidgetTester tester) => tester
    .widgetList<UtenAppBarActionButton>(find.byType(UtenAppBarActionButton))
    .singleWhere((button) => button.label == '刷新');

UtenButton _submitButton(WidgetTester tester, bool sheet) =>
    tester.widget<UtenButton>(
      find.byKey(
        Key(sheet ? 'fqc-sheet-submit-report' : 'fqc-inspection-submit-report'),
      ),
    );

Future<void> _openConfirmation(WidgetTester tester, bool sheet) async {
  final button = find.byKey(
    Key(sheet ? 'fqc-sheet-submit-report' : 'fqc-inspection-submit-report'),
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  for (final sheet in [false, true]) {
    testWidgets(
      'FQC sheet=$sheet pending refresh blocks new report confirmation',
      (tester) async {
        final api = _FqcApi();
        await _mount(tester, api, sheet: sheet);
        final gate = Completer<void>();
        api.readGates[sheet ? _sheetId : _id] = gate.future;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        _refreshButton(tester).onPressed!();
        await tester.pump(const Duration(milliseconds: 100));
        final button = _submitButton(tester, sheet);
        expect(
          button.onPressed,
          isNull,
          reason:
              'The reviewed rows cannot be submitted while their GET is still pending.',
        );
        expect(api.calls, isEmpty);
        gate.complete();
        await tester.pumpAndSettle();
        expect(_submitButton(tester, sheet).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'FQC sheet=$sheet confirmation blocks queued refresh and retains its original row',
      (tester) async {
        final api = _FqcApi();
        await _mount(tester, api, sheet: sheet);
        final row = _rows(tester, sheet: sheet).single;
        row.pass.text = '3';
        final queuedRefresh = _refreshButton(tester).onPressed!;
        final reads = api.reads;
        await _openConfirmation(tester, sheet);
        expect(find.byType(AlertDialog), findsOneWidget);
        final gate = Completer<void>();
        api.readGates[sheet ? _sheetId : _id] = gate.future;
        queuedRefresh();
        await tester.pump(const Duration(milliseconds: 100));
        gate.complete();
        await tester.pumpAndSettle();
        expect(
          identical(_rows(tester, sheet: sheet).single, row),
          isTrue,
          reason:
              'A queued GET must not replace and dispose the row shown in the confirmation.',
        );
        expect(api.reads, reads);
        expect(_refreshButton(tester).onPressed, isNull);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        api.readGates.clear();
        expect(_refreshButton(tester).onPressed, isNotNull);
        _refreshButton(tester).onPressed!();
        await tester.pumpAndSettle();
        expect(api.reads, reads + 1);
        expect(_rows(tester, sheet: sheet).single.pass.text, '3');
        await _submit(tester, sheet: sheet);
        expect(api.calls.single.body['passQty'], 3);
        expect(api.commits, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'FQC sheet=$sheet changed quantity invalidates the reviewed confirmation before dispatch',
      (tester) async {
        final api = _FqcApi();
        await _mount(tester, api, sheet: sheet);
        final row = _rows(tester, sheet: sheet).single;
        row.pass.text = '3';
        await _openConfirmation(tester, sheet);
        // Modal pointer blocking alone cannot bind a command to its displayed facts.
        row.pass.text = '8';
        await tester.tap(
          find.byKey(const Key('inspection-report-confirm-submit')),
        );
        await tester.pumpAndSettle();
        expect(
          api.calls,
          isEmpty,
          reason:
              'The modal reviewed 3, so a changed body of 8 must not dispatch.',
        );
        expect(row.submission, isNull);
        expect(_refreshButton(tester).onPressed, isNotNull);
        await _submit(tester, sheet: sheet);
        expect(api.calls.single.body['passQty'], 8);
        expect(api.commits, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'FQC sheet=$sheet older GET cannot replace the latest row after confirmation is canceled',
      (tester) async {
        final api = _FqcApi();
        await _mount(tester, api, sheet: sheet);
        final refresh = _refreshButton(tester).onPressed!;
        final oldRead = Completer<void>();
        api.readGates[sheet ? _sheetId : _id] = oldRead.future;
        addTearDown(() {
          if (!oldRead.isCompleted) oldRead.complete();
        });
        refresh();
        await tester.pump(const Duration(milliseconds: 100));
        api.readGates.clear();
        // A queued second refresh completes ahead of the older response.
        refresh();
        await tester.pumpAndSettle();
        final latest = _rows(tester, sheet: sheet).single;
        latest.pass.text = '3';
        await _openConfirmation(tester, sheet);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(_refreshButton(tester).onPressed, isNotNull);
        oldRead.complete();
        await tester.pumpAndSettle();
        expect(
          identical(_rows(tester, sheet: sheet).single, latest),
          isTrue,
          reason:
              'Canceling the dialog must not revive a previously superseded GET.',
        );
        expect(latest.pass.text, '3');
        expect(api.calls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'FQC sheet=$sheet sending blocks queued refresh until its command settles',
      (tester) async {
        final api = _FqcApi();
        await _mount(tester, api, sheet: sheet);
        final row = _rows(tester, sheet: sheet).single;
        row.pass.text = '3';
        final queuedRefresh = _refreshButton(tester).onPressed!;
        final reads = api.reads;
        final sendGate = Completer<void>();
        addTearDown(() {
          if (!sendGate.isCompleted) sendGate.complete();
        });
        api.responseGate = sendGate.future;
        await _startSubmit(tester, sheet: sheet);
        expect(api.calls, hasLength(1));
        final original = jsonEncode(api.calls.single.body);
        queuedRefresh();
        await tester.pump(const Duration(milliseconds: 100));
        expect(identical(_rows(tester, sheet: sheet).single, row), isTrue);
        expect(api.reads, reads);
        expect(_refreshButton(tester).onPressed, isNull);
        sendGate.complete();
        await tester.pumpAndSettle();
        expect(api.calls, hasLength(1));
        expect(jsonEncode(api.calls.single.body), original);
        expect(api.commits, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'FQC sheet=$sheet unknown command keeps its original body across cancel and factual refresh',
      (tester) async {
        final api = _FqcApi()..outcomes.add(NetworkTimeoutException());
        await _mount(tester, api, sheet: sheet);
        final row = _rows(tester, sheet: sheet).single;
        row.pass.text = '4';
        row.fail.text = '2';
        await _submit(tester, sheet: sheet, reason: '坏件待处理');
        final original = jsonEncode(api.calls.single.body);
        final reads = api.reads;
        api.statusOverride = 'PASSED';
        _refreshButton(tester).onPressed!();
        await tester.pumpAndSettle();
        expect(api.reads, reads + 1);
        expect(_rows(tester, sheet: sheet).single.needsReconciliation, isTrue);
        await _openConfirmation(tester, sheet);
        expect(find.text('继续原提交'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(_refreshButton(tester).onPressed, isNotNull);
        api.statusOverride = null;
        _refreshButton(tester).onPressed!();
        await tester.pumpAndSettle();
        expect(api.reads, reads + 2);
        await _submit(tester, sheet: sheet, recovery: true);
        expect(api.calls, hasLength(2));
        expect(jsonEncode(api.calls.last.body), original);
        expect(api.commits, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
