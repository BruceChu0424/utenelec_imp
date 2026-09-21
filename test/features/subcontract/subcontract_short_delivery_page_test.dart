// ADR-098 委外回厂短交判定页：待判定段渲染、两种判定弹窗与请求体、通知深链打开详情。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/shared/models/subcontract_short_delivery.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_short_delivery_page.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_short_delivery_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

class _NoopApi extends ApiClient {
  _NoopApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => <String, dynamic>{};
}

class _FakeRepo extends SubcontractShortDeliveryRepository {
  _FakeRepo(this.rows) : super(_NoopApi());

  final List<SubcontractShortDeliveryCase> rows;
  final List<Map<String, dynamic>> decisions = [];
  final List<String> segments = [];

  @override
  Future<PagedResult<SubcontractShortDeliveryCase>> list({
    String segment = 'PENDING',
    String? keyword,
    String? supplierId,
    String? orderId,
    String? dateFrom,
    String? dateTo,
    int page = 1,
    int size = 50,
  }) async {
    segments.add(segment);
    final items = rows.where((r) {
      final pending = r.effectiveStatus == 'PENDING_OWNER' && r.isBelowFloor;
      final tolerant = r.effectiveStatus == 'PENDING_OWNER' && !r.isBelowFloor;
      final waiting = r.effectiveStatus == 'WAITING_MORE';
      return switch (segment) {
        'PENDING' => pending,
        'TOLERANT' => tolerant,
        'WAITING' => waiting,
        _ => !pending && !tolerant && !waiting,
      };
    }).toList();
    return PagedResult(
      items: items,
      page: 1,
      size: 50,
      total: items.length,
      totalPages: 1,
    );
  }

  @override
  Future<SubcontractShortDeliveryCounts> counts() async =>
      SubcontractShortDeliveryCounts(
        pending: rows
            .where(
              (r) => r.effectiveStatus == 'PENDING_OWNER' && r.isBelowFloor,
            )
            .length,
        tolerant: rows
            .where(
              (r) => r.effectiveStatus == 'PENDING_OWNER' && !r.isBelowFloor,
            )
            .length,
        waiting: rows.where((r) => r.effectiveStatus == 'WAITING_MORE').length,
      );

  @override
  Future<SubcontractShortDeliveryDetail> detail(String id) async =>
      SubcontractShortDeliveryDetail(
        row: rows.firstWhere((r) => r.id == id),
        events: const [
          SubcontractShortDeliveryEvent(
            id: 'e-1',
            eventType: 'DETECTED',
            actorName: '仓库小王',
            createdAt: '2026-09-20T08:00:00Z',
          ),
        ],
      );

  @override
  Future<SubcontractShortDeliveryDetail> decide(
    String id, {
    required String decision,
    required int expectedVersion,
    String? expectedCompleteBy,
    String? note,
  }) async {
    decisions.add({
      'id': id,
      'decision': decision,
      'expectedVersion': expectedVersion,
      'expectedCompleteBy': expectedCompleteBy,
      'note': note,
    });
    final row = rows.firstWhere((r) => r.id == id);
    return SubcontractShortDeliveryDetail(
      row: SubcontractShortDeliveryCase(
        id: row.id,
        orderId: row.orderId,
        orderBillNo: row.orderBillNo,
        orderItemId: row.orderItemId,
        orderedQty: row.orderedQty,
        deliveredQty: row.deliveredQty,
        shortfallQty: row.shortfallQty,
        shortfallPct: row.shortfallPct,
        severity: row.severity,
        status: decision == 'WAIT_MORE' ? 'WAITING_MORE' : 'ACCEPTED_LOSS',
        effectiveStatus: decision == 'WAIT_MORE'
            ? 'WAITING_MORE'
            : 'ACCEPTED_LOSS',
        expectedCompleteBy: expectedCompleteBy,
        wasteBillNo: decision == 'WAIT_MORE' ? null : 'SW-1',
        version: row.version + 1,
      ),
    );
  }
}

SubcontractShortDeliveryCase _case({
  required String id,
  required String severity,
  String status = 'PENDING_OWNER',
  String? expectedCompleteBy,
  bool canDecide = true,
}) => SubcontractShortDeliveryCase(
  id: id,
  orderId: 'order-$id',
  orderBillNo: 'EO-$id',
  orderItemId: 'item-$id',
  lineNo: 1,
  supplierId: 'sup-1',
  supplierName: '精工委外厂',
  goodsId: 'g-1',
  goodsCode: 'FG-100',
  goodsName: '委外件A',
  colorName: '本色',
  unitName: '件',
  receiptBillNo: 'SR-$id',
  orderedQty: 100,
  allowedLossPct: 5,
  floorQty: 95,
  deliveredQty: 60,
  shortfallQty: 40,
  shortfallPct: 40,
  severity: severity,
  status: status,
  effectiveStatus: status,
  expectedCompleteBy: expectedCompleteBy,
  ownerName: '委外小李',
  detectedAt: '2026-09-20T08:00:00Z',
  version: 3,
  canDecide: canDecide,
);

Future<_FakeRepo> _pump(
  WidgetTester tester, {
  required List<SubcontractShortDeliveryCase> rows,
  String? initialCaseId,
}) async {
  // 判定页表格列多(操作列在最右)：视口拉宽到 3000 让操作按钮在可点击范围内。
  tester.view.physicalSize = const Size(3000, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repo = _FakeRepo(rows);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(const {
          Perm.subcontractOrderView,
        }),
        apiClientProvider.overrideWithValue(_NoopApi()),
      ],
      child: MaterialApp(
        home: Column(
          children: [
            const AppNotificationHost(),
            Expanded(
              child: SubcontractShortDeliveryPage(
                repository: repo,
                initialCaseId: initialCaseId,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('待判定段：严重短交带标签与操作按钮，接受损耗必须填说明后才提交', (tester) async {
    final repo = await _pump(
      tester,
      rows: [_case(id: 'a', severity: 'SEVERE')],
    );
    expect(repo.segments.first, 'PENDING');
    expect(find.text('EO-a'), findsOneWidget);
    expect(find.text('精工委外厂'), findsOneWidget);
    expect(find.text('严重短交'), findsOneWidget);
    expect(find.text('40%'), findsWidgets);
    expect(
      find.byKey(const ValueKey('short-delivery-accept-a')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('short-delivery-accept-a')));
    await tester.pumpAndSettle();
    expect(find.text('接受损耗，结案'), findsOneWidget);
    expect(find.textContaining('自动做三件事'), findsOneWidget);
    // 低于允许下限：说明必填，没填之前确认按钮禁用。
    await tester.tap(find.byKey(const Key('short-delivery-accept-confirm')));
    await tester.pumpAndSettle();
    expect(repo.decisions, isEmpty);
    await tester.enterText(
      find.byKey(const Key('short-delivery-accept-note')),
      '委外商确认报废 40 件',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('short-delivery-accept-confirm')));
    await tester.pumpAndSettle();
    expect(repo.decisions.length, 1);
    expect(repo.decisions.single['decision'], 'ACCEPT_LOSS');
    expect(repo.decisions.single['note'], '委外商确认报废 40 件');
    expect(repo.decisions.single['expectedVersion'], 3);
    expect(repo.decisions.single['expectedCompleteBy'], isNull);
    expect(find.textContaining('已接受损耗结案'), findsOneWidget);
  });

  testWidgets('分批到货：预计到齐日必填，已有值时直接确认并带日期提交', (tester) async {
    final future = DateTime.now().add(const Duration(days: 7));
    final date =
        '${future.year.toString().padLeft(4, '0')}-'
        '${future.month.toString().padLeft(2, '0')}-'
        '${future.day.toString().padLeft(2, '0')}';
    final repo = await _pump(
      tester,
      rows: [_case(id: 'b', severity: 'BELOW_FLOOR', expectedCompleteBy: date)],
    );
    await tester.tap(find.byKey(const ValueKey('short-delivery-wait-b')));
    await tester.pumpAndSettle();
    expect(find.text('分批到货，继续等'), findsOneWidget);
    await tester.tap(find.byKey(const Key('short-delivery-wait-confirm')));
    await tester.pumpAndSettle();
    expect(repo.decisions.single['decision'], 'WAIT_MORE');
    expect(repo.decisions.single['expectedCompleteBy'], date);
    expect(find.textContaining('已判定为分批到货'), findsOneWidget);
  });

  testWidgets('无判定权限只能看；通知深链直接打开案件详情与过程记录', (tester) async {
    await _pump(
      tester,
      rows: [_case(id: 'c', severity: 'WITHIN_TOLERANCE', canDecide: false)],
      initialCaseId: 'c',
    );
    expect(find.text('短交案件 · EO-c'), findsOneWidget);
    expect(find.text('过程记录'), findsOneWidget);
    expect(find.textContaining('仓库登记发现短交'), findsOneWidget);
    expect(find.byKey(const Key('short-delivery-detail-accept')), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    // 容差内的短交不在红色「待判定」段，在中性「容差内待结案」段。
    expect(find.text('无判定权限'), findsNothing);
    await tester.tap(find.text('容差内待结案'));
    await tester.pumpAndSettle();
    expect(find.text('无判定权限'), findsOneWidget);
    expect(find.text('容差内未到齐'), findsOneWidget);
  });
}
