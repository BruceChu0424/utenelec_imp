import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/reportable_plan_line.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/widgets/reportable_plan_line_picker.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import '../../../support/uten_test_actions.dart';

void main() {
  testWidgets(
    'complete reportable tasks keep source identity and click order',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final requests = <(int, int)>[];
      final first = _recovery(
        id: 'rework-page-one',
        disposition: 'REWORK',
        maxReportQty: 2,
        requiresMaterial: false,
      );
      final second = {
        ..._recovery(
          id: 'sales-page-two',
          disposition: 'REWORK',
          maxReportQty: 2,
          requiresMaterial: false,
        ),
        'fqcRecoveryAuthorizationId': null,
        'fqcRecoveryDispositionCode': null,
        'orderItemId': 'order-page-two',
        'executionSegmentSalesAllocationId': 'allocation-page-two',
      };
      // 2026-11-08 阶梯完整读取：fake 按请求的 (page,size) 切片 101 行并回显，
      // 首行 rework-page-one、末行 sales-page-two。
      final all = [
        first,
        for (var index = 1; index < 100; index++)
          _recovery(
            id: 'filler-$index',
            disposition: 'REWORK',
            maxReportQty: 2,
            requiresMaterial: false,
          ),
        second,
      ];
      final api = _pagedApi((request) async {
        final page = request.queryParameters['page'] as int;
        final size = request.queryParameters['size'] as int;
        requests.add((page, size));
        return {
          'items': all.skip((page - 1) * size).take(size).toList(),
          'page': page,
          'size': size,
          'total': all.length,
          'totalPages': (all.length + size - 1) ~/ size,
        };
      });
      List<ReportablePlanLine>? selected;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionDailyReportRepositoryProvider.overrideWithValue(
              ProductionDailyReportRepository(api),
            ),
          ],
          child: MaterialApp(
            home: _PickerHost(onSelected: (value) => selected = value),
          ),
        ),
      );
      await tester.tap(find.text('选择来源'));
      await tester.pumpAndSettle();
      final rows = _reportableTable(tester).rowsController!;
      // 101 行 = 50 → 50 → 100（末批 1 行）。
      expect(requests, [(1, 50), (2, 50), (2, 100)]);
      expect(rows.items, hasLength(101));
      expect(_reportableTable(tester).totalPages, 1);
      final controller = utenTestTableBodyController(
        tester,
        find.byType(MasterDataTableView<ReportablePlanLine>),
      );
      final vertical = find.byWidgetPredicate(
        (widget) => widget is Scrollable && widget.controller == controller,
      );
      for (final id in ['sales-page-two', 'rework-page-one']) {
        controller.jumpTo(
          id == 'sales-page-two' ? controller.position.maxScrollExtent : 0,
        );
        await tester.pumpAndSettle();
        final row = find.textContaining('SJ-$id');
        await tester.scrollUntilVisible(
          row,
          id == 'sales-page-two' ? 500 : -500,
          scrollable: vertical,
        );
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await tester.tap(row);
        await tester.pumpAndSettle();
      }
      expect(requests, [
        (1, 50),
        (2, 50),
        (2, 100),
      ], reason: 'Scrolling the complete result performs no read');
      await tester.tap(find.widgetWithText(UtenButton, '确定'));
      await tester.pumpAndSettle();
      expect(selected?.map((row) => row.planNo), [
        'SJ-sales-page-two',
        'SJ-rework-page-one',
      ]);
      expect(
        selected?.first.executionSegmentSalesAllocationId,
        'allocation-page-two',
      );
      expect(selected?.last.fqcRecoveryAuthorizationId, 'rework-page-one');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new reportable search invalidates a pending complete previous query',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pendingPage = Completer<Map<String, dynamic>>();
      final requests = <(int, String?)>[];
      Map<String, dynamic> response(String id, int page) => {
        'items': [
          for (var index = 0; index < (page == 1 ? 100 : 1); index++)
            _recovery(
              id: index == 0 ? id : '$id-$index',
              disposition: 'REWORK',
              maxReportQty: 2,
              requiresMaterial: false,
            ),
        ],
        'page': page,
        'size': 100,
        'total': 101,
        'totalPages': 2,
      };
      final api = _pagedApi((request) async {
        final page = request.queryParameters['page'] as int;
        final keyword = request.queryParameters['keyword'] as String?;
        requests.add((page, keyword));
        if (page == 2 && keyword == null) return pendingPage.future;
        return response(keyword == null ? 'old-first' : 'new-first', page);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionDailyReportRepositoryProvider.overrideWithValue(
              ProductionDailyReportRepository(api),
            ),
          ],
          child: const MaterialApp(home: _PickerHost()),
        ),
      );
      await tester.tap(find.text('选择来源'));
      for (var frame = 0; frame < 200 && requests.length < 2; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(requests, [(1, null), (2, null)]);
      expect(pendingPage.isCompleted, isFalse);
      // 2026-11-08 逐批读取：fake 自有 100 行页大小，首批校验通过即作为
      // 增长期 provisional 行展示；续批未到前它不是完整结果。
      final provisional = _reportableTable(tester).items;
      expect(provisional, hasLength(100));
      expect(readWindowBindingOf(provisional)!.growing, isTrue);
      final search = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == '计划号 / 产品 / 订单号 / 客户',
      );
      await tester.enterText(search, 'new');
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pumpAndSettle();
      expect(requests, [(1, null), (2, null), (1, 'new'), (2, 'new')]);
      expect(_reportableTable(tester).items, hasLength(101));
      expect(pendingPage.isCompleted, isFalse);
      pendingPage.complete(response('old-late', 2));
      await tester.pumpAndSettle();
      expect(find.text('SJ-new-first\nSEG-001'), findsOneWidget);
      expect(find.textContaining('SJ-old-late'), findsNothing);
      expect(_reportableTable(tester).currentPage, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('375px picker blocks replacement and returns REWORK identity', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = ProductionDailyReportRepository(_api());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionDailyReportRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: _PickerHost()),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(_PickerHost)),
    );
    await tester.tap(find.text('选择来源'));
    await tester.pumpAndSettle();

    expect(find.text('返工再检'), findsOneWidget);
    expect(find.text('报废补产'), findsOneWidget);
    expect(find.text('待补料/待发料'), findsOneWidget);

    final scrap = find.textContaining('SJ-recovery-scrap');
    await tester.ensureVisible(scrap);
    await tester.pumpAndSettle();
    await tester.tap(scrap);
    await tester.pumpAndSettle();
    expect(
      container.read(appNotificationProvider).single.message,
      contains('尚未完成新增物料齐套和仓库发料'),
    );
    expect(
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '确定'))
          .onPressed,
      isNull,
    );

    final rework = find.textContaining('SJ-recovery-rework');
    await tester.ensureVisible(rework);
    await tester.pumpAndSettle();
    await tester.tap(rework);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(UtenButton, '确定'));
    await tester.pumpAndSettle();

    expect(find.text('已选返工再检 · recovery-rework'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一计划行的销售分摊和品质恢复授权分别选择，按点选次序返回', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final rows = [
      for (final id in ['rework-a', 'rework-b'])
        _recovery(
          id: id,
          disposition: 'REWORK',
          maxReportQty: 2,
          requiresMaterial: false,
        ),
      for (final id in ['sales-a', 'sales-b'])
        {
          ..._recovery(
            id: id,
            disposition: 'REWORK',
            maxReportQty: 2,
            requiresMaterial: false,
          ),
          'fqcRecoveryAuthorizationId': null,
          'fqcRecoveryDispositionCode': null,
          'orderItemId': 'order-$id',
          'executionSegmentSalesAllocationId': 'allocation-$id',
        },
    ];
    List<ReportablePlanLine>? selected;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionDailyReportRepositoryProvider.overrideWithValue(
            ProductionDailyReportRepository(_api(rows: rows)),
          ),
        ],
        child: MaterialApp(
          home: _PickerHost(onSelected: (value) => selected = value),
        ),
      ),
    );
    await tester.tap(find.text('选择来源'));
    await tester.pumpAndSettle();
    for (final id in ['sales-b', 'rework-a', 'sales-a', 'rework-b']) {
      final row = find.textContaining('SJ-$id');
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.widgetWithText(UtenButton, '确定'));
    await tester.pumpAndSettle();
    expect(selected?.map((line) => line.planNo), [
      'SJ-sales-b',
      'SJ-rework-a',
      'SJ-sales-a',
      'SJ-rework-b',
    ]);
    expect(
      selected?[0].executionSegmentSalesAllocationId,
      'allocation-sales-b',
    );
    expect(selected?[1].fqcRecoveryAuthorizationId, 'rework-a');
    expect(tester.takeException(), isNull);
  });
}

MasterDataTableView<ReportablePlanLine> _reportableTable(WidgetTester tester) =>
    tester.widget<MasterDataTableView<ReportablePlanLine>>(
      find.byType(MasterDataTableView<ReportablePlanLine>),
    );

ApiClient _pagedApi(
  Future<Map<String, dynamic>> Function(RequestOptions) respond,
) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) async {
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: await respond(request),
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

class _PickerHost extends ConsumerStatefulWidget {
  const _PickerHost({this.onSelected});
  final ValueChanged<List<ReportablePlanLine>>? onSelected;

  @override
  ConsumerState<_PickerHost> createState() => _PickerHostState();
}

class _PickerHostState extends ConsumerState<_PickerHost> {
  ReportablePlanLine? selected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: selected == null
            ? FilledButton(
                onPressed: () async {
                  final result = await showReportablePlanLinePicker(
                    context,
                    ref,
                  );
                  // 2026-09-11 起选择器返回**列表**（支持多选）；
                  // 本用例只点一条，取首条即可。
                  if (mounted && result != null && result.isNotEmpty) {
                    widget.onSelected?.call(result);
                    setState(() => selected = result.first);
                  }
                },
                child: const Text('选择来源'),
              )
            : Text(
                '已选${selected!.fqcRecoveryLabel} · '
                '${selected!.fqcRecoveryAuthorizationId}',
              ),
      ),
    );
  }
}

ApiClient _api({List<Map<String, dynamic>>? rows}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: {
              'items':
                  rows ??
                  [
                    _recovery(
                      id: 'recovery-rework',
                      disposition: 'REWORK',
                      maxReportQty: 2,
                      requiresMaterial: false,
                    ),
                    _recovery(
                      id: 'recovery-scrap',
                      disposition: 'SCRAP',
                      maxReportQty: 0,
                      requiresMaterial: true,
                    ),
                  ],
              'page': 1,
              'size': 100,
              'total': rows?.length ?? 2,
              'totalPages': 1,
            },
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

Map<String, dynamic> _recovery({
  required String id,
  required String disposition,
  required double maxReportQty,
  required bool requiresMaterial,
}) => {
  'planItemId': 'plan-item-1',
  'executionSegmentId': 'segment-1',
  'executionSegmentCode': 'SEG-001',
  'executionSegmentStatus': 'IN_PROGRESS',
  'planNo': 'SJ-$id',
  'goodsId': 'goods-1',
  'goodsCode': 'V51043',
  'goodsName': '酸洗插套',
  'unitId': 'unit-1',
  'unitRate': 1,
  'remainingPlanQty': 2,
  'maxReportQty': maxReportQty,
  'fqcRecoveryAuthorizationId': id,
  'fqcRecoveryDispositionCode': disposition,
  'fqcRecoveryAvailableQty': 2,
  'fqcSourceInspectionId': 'inspection-1',
  'fqcSourceReportItemId': 'source-report-item-1',
  'fqcSourceReportNo': 'RB-001',
  'fqcRecoveryRequiresMaterial': requiresMaterial,
};
