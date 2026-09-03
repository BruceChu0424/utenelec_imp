import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_arrival_batch_registration_page.dart';

const _reportA = '20000000-0000-0000-0000-000000000001';
const _reportB = '20000000-0000-0000-0000-000000000002';
const _itemA = '30000000-0000-0000-0000-000000000001';
const _itemB = '30000000-0000-0000-0000-000000000002';
const _itemA2 = '30000000-0000-0000-0000-000000000003';

void main() {
  testWidgets('批量登记页合并多报工明细、预选上次仓、按单分组提交并批量记忆', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchArrivalApi();
    await _openBatchPage(tester, api: api);

    expect(find.text('批量登记成品仓与库位'), findsOneWidget);
    expect(find.text('RB202608300001'), findsOneWidget);
    expect(find.text('RB202608300002'), findsOneWidget);

    // 上次登记的仓已预选为默认仓，自动落到全部行并批量拉了建议。
    expect(api.suggestionRequests, contains('warehouse-1'));
    expect(
      tester.widget<TextField>(_placeField(_itemA)).controller?.text,
      'WH-A-01',
    );
    expect(
      tester.widget<TextField>(_placeField(_itemB)).controller?.text,
      'WH-B-01',
    );

    // B 行手改库位后提交：确认弹窗拦一道，确认后按单分组提交。
    await tester.enterText(_placeField(_itemB), 'CP-B-02');
    _pressSubmit(tester);
    await tester.pumpAndSettle();
    expect(api.lastPostPath, isNull);
    await tester.tap(find.text('确认登记并送检'));
    await tester.pumpAndSettle();

    expect(
      api.lastPostPath,
      '/warehouse/production-finished-in/arrival-registrations/batch',
    );
    final body = api.lastPostBody!;
    expect(body['idempotencyKey'], isA<String>());
    final reports = (body['reports'] as List).cast<Map<String, dynamic>>();
    expect(reports, hasLength(2));
    expect(
      reports.map((r) => r['reportId']),
      containsAll([_reportA, _reportB]),
    );
    for (final report in reports) {
      expect(report['warehouseId'], 'warehouse-1');
    }
    final itemsA =
        (reports.firstWhere((r) => r['reportId'] == _reportA)['items'] as List)
            .cast<Map<String, dynamic>>();
    expect(itemsA.single['reportItemId'], _itemA);
    expect(itemsA.single['place'], 'WH-A-01');
    final itemsB =
        (reports.firstWhere((r) => r['reportId'] == _reportB)['items'] as List)
            .cast<Map<String, dynamic>>();
    expect(itemsB.single['place'], 'CP-B-02');
    expect(api.rememberBatchCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一报工单的行选了不同仓会被拦下', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 报工 A 有两行明细；无上次仓历史 → 行上仓为空，逐行选择不同仓。
    final api = _BatchArrivalApi(
      twoItemsInFirstReport: true,
      withLastWarehouse: false,
    );
    await _openBatchPage(tester, api: api);
    await tester.pumpAndSettle();

    // 报工 A 两行分别选不同仓；报工 B 的行也分配好仓与库位（不参与冲突）。
    await tester.tap(find.text('点击选择成品仓').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('成品仓').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('点击选择成品仓').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('备用成品仓').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('点击选择成品仓').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('成品仓').last);
    await tester.pumpAndSettle();

    await tester.enterText(_placeField(_itemA), 'CP-A-01');
    await tester.enterText(_placeField(_itemA2), 'CP-A-02');
    await tester.enterText(_placeField(_itemB), 'CP-B-01');
    // 校验先于确认弹窗：同一报工单跨仓直接被拦下。
    _pressSubmit(tester);
    await tester.pump();

    expect(api.lastPostPath, isNull);
    expect(find.textContaining('只能登记到一个仓'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Finder _placeField(String reportItemId) => find.byKey(
  ValueKey('production-finished-arrival-batch-place-$reportItemId'),
);

void _pressSubmit(WidgetTester tester) {
  tester
      .widget<UtenButton>(
        find.byKey(const Key('production-finished-arrival-batch-submit')),
      )
      .onPressed!
      .call();
}

Future<void> _openBatchPage(
  WidgetTester tester, {
  required _BatchArrivalApi api,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                key: const Key('open-batch-registration'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const ProductionFinishedArrivalBatchRegistrationPage(
                          reportIds: [_reportA, _reportB],
                          canRegister: true,
                        ),
                  ),
                ),
                child: const Text('打开批量登记'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-batch-registration')));
  await tester.pumpAndSettle();
}

class _BatchArrivalApi extends ApiClient {
  _BatchArrivalApi({
    this.twoItemsInFirstReport = false,
    this.withLastWarehouse = true,
  }) : super(Dio());

  final bool twoItemsInFirstReport;
  final bool withLastWarehouse;

  String? lastPostPath;
  Map<String, dynamic>? lastPostBody;
  int rememberBatchCalls = 0;
  final List<String> suggestionRequests = [];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/warehouses/dict') {
      return const [
        {'id': 'warehouse-1', 'name': '成品仓'},
        {'id': 'warehouse-2', 'name': '备用成品仓'},
      ];
    }
    if (path ==
        '/warehouse/production-finished-in/arrival-registrations/batch') {
      return [
        _reportJson(
          _reportA,
          'RB202608300001',
          twoItemsInFirstReport ? [_itemA, _itemA2] : [_itemA],
          'a0000000-0000-0000-0000-000000000001',
          'V51043',
          '三极插套',
        ),
        _reportJson(
          _reportB,
          'RB202608300002',
          [_itemB],
          'a0000000-0000-0000-0000-000000000002',
          'V51044',
          '两极插套',
        ),
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/tasks/count')) {
      return const {'count': 2};
    }
    if (path.endsWith('/last-warehouse')) {
      return withLastWarehouse
          ? const {
              'warehouseId': 'warehouse-1',
              'warehouseCode': 'CP',
              'warehouseName': '成品仓',
              'usedAt': '2026-09-01T08:30:00Z',
            }
          : const <String, dynamic>{};
    }
    if (path.endsWith('/batch/place-suggestions')) {
      final warehouseId = query?['warehouseId']?.toString() ?? '';
      suggestionRequests.add(warehouseId);
      return {
        'items': [
          if (warehouseId == 'warehouse-1') ...[
            {
              'reportItemId': _itemA,
              'place': 'WH-A-01',
              'source': 'WAREHOUSE_PREFERENCE',
            },
            {
              'reportItemId': _itemA2,
              'place': 'WH-A-02',
              'source': 'WAREHOUSE_PREFERENCE',
            },
            {
              'reportItemId': _itemB,
              'place': 'WH-B-01',
              'source': 'GOODS_MASTER',
            },
          ],
        ],
      };
    }
    throw StateError('Unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path.endsWith('/batch/remember-places')) {
      rememberBatchCalls++;
      return const {
        'remembered': 2,
        'unchanged': 0,
        'ambiguous': 0,
        'warnings': <String>[],
      };
    }
    lastPostPath = path;
    lastPostBody = Map<String, dynamic>.from(body! as Map);
    return {
      'registeredCount': 2,
      'reports': const [
        {
          'reportId': _reportA,
          'reportNo': 'RB202608300001',
          'warehouseId': 'warehouse-1',
          'warehouseName': '成品仓',
        },
        {
          'reportId': _reportB,
          'reportNo': 'RB202608300002',
          'warehouseId': 'warehouse-1',
          'warehouseName': '成品仓',
        },
      ],
    };
  }

  Map<String, dynamic> _reportJson(
    String reportId,
    String reportNo,
    List<String> itemIds,
    String goodsId,
    String goodsCode,
    String goodsName,
  ) => {
    'registrationId': null,
    'registered': false,
    'reportId': reportId,
    'reportNo': reportNo,
    'reportDate': '2026-08-30',
    'workshopName': '注塑车间',
    'warehouseId': null,
    'receiverName': '仓库管理员',
    'items': [
      for (var index = 0; index < itemIds.length; index++)
        {
          'reportItemId': itemIds[index],
          'lineNo': 1,
          // 同报工多行时给不同货品：避免「同时记住」歧义拦截先于本用例断言。
          'goodsId': index == 0
              ? goodsId
              : 'a0000000-0000-0000-0000-000000000003',
          'goodsCode': index == 0 ? goodsCode : 'V51045',
          'goodsName': index == 0 ? goodsName : '插座面板',
          'colorName': '—',
          'unitName': '只',
          'reportedQty': 10,
          'place': null,
          'placeHint': null,
        },
    ],
  };
}
