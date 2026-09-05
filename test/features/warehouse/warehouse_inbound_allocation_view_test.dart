import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_iqc_stock_in.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_inbound_allocation_view.dart';

void main() {
  testWidgets(
    'partial quantity preview truncates allocations in server order',
    (tester) async {
      final allocations = [
        _allocation(WarehouseInboundAllocationKind.formalDemand, 2),
        _allocation(WarehouseInboundAllocationKind.exactAnalysis, 4),
        _allocation(WarehouseInboundAllocationKind.sharedClaim, 3),
        _allocation(WarehouseInboundAllocationKind.publicStock, 1),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => SizedBox(
                width: 260,
                child: WarehouseInboundAllocationSummary(
                  allocations: allocations,
                  previewQty: 6,
                  qtyText: _qty,
                  onTap: () => showWarehouseInboundAllocationDetails(
                    context,
                    title: '预计去向',
                    sections: [
                      WarehouseInboundAllocationSection(
                        id: 'pass-1',
                        goodsLabel: 'G-001 · 测试物料',
                        quantity: 6,
                        unitName: '件',
                        allocations: allocations,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('正式工单 2 · 本分析预定 4'), findsOneWidget);
      await tester.tap(find.text('正式工单 2 · 本分析预定 4'));
      await tester.pumpAndSettle();
      expect(find.text('正式工单'), findsOneWidget);
      expect(find.text('本分析预定'), findsOneWidget);
      expect(find.text('公共在途已采用'), findsNothing);
      expect(find.text('公共库存'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cross-warehouse warning is explicit at 375px and 1.3x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const allocation = WarehouseInboundAllocation(
      kind: WarehouseInboundAllocationKind.publicStock,
      qty: 5,
      actualWarehouseId: 'w2',
      actualWarehouseName: 'W2',
      intendedWarehouseNames: ['W1', 'W3'],
      warehouseMatches: false,
      sourceLabel: '公共库存',
      formationStatus: '来源预定主仓与本次入库仓不一致；本数量不会跨仓绑定，按实际仓公共入库',
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => SizedBox(
              width: 240,
              child: WarehouseInboundAllocationSummary(
                allocations: const [allocation],
                previewQty: 5,
                qtyText: _qty,
                onTap: () => showWarehouseInboundAllocationDetails(
                  context,
                  title: '跨仓预计去向',
                  sections: [
                    const WarehouseInboundAllocationSection(
                      id: 'pass-cross',
                      goodsLabel: 'G-002 · 跨仓物料',
                      quantity: 5,
                      unitName: '件',
                      allocations: [allocation],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('跨仓 · 本次全量 5 不绑定计划'), findsOneWidget);
    await tester.tap(find.textContaining('跨仓 · 本次全量 5 不绑定计划'));
    await tester.pumpAndSettle();
    expect(
      find.text('实际 W2，预定 W1 / W3；本次全量 5 件 不绑定计划，按实际仓进入公共库存。'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('warehouse-inbound-allocation-cross-warehouse')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mixed same-warehouse and cross-warehouse quantities stay distinct',
    (tester) async {
      final allocations = [
        _allocation(WarehouseInboundAllocationKind.exactAnalysis, 4),
        const WarehouseInboundAllocation(
          kind: WarehouseInboundAllocationKind.publicStock,
          qty: 1,
          actualWarehouseName: 'W2',
          intendedWarehouseNames: ['W1', 'W3'],
          warehouseMatches: false,
          sourceLabel: '公共库存',
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => SizedBox(
                width: 300,
                child: WarehouseInboundAllocationSummary(
                  allocations: allocations,
                  previewQty: 5,
                  qtyText: _qty,
                  onTap: () => showWarehouseInboundAllocationDetails(
                    context,
                    title: '混合去向',
                    sections: [
                      WarehouseInboundAllocationSection(
                        id: 'mixed',
                        goodsLabel: 'G-003 · 混合物料',
                        quantity: 5,
                        unitName: '件',
                        allocations: allocations,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('跨仓部分 1 不绑定计划 · 其余按预定分配'), findsOneWidget);
      await tester.tap(find.text('跨仓部分 1 不绑定计划 · 其余按预定分配'));
      await tester.pumpAndSettle();
      expect(find.textContaining('跨仓部分 1 件 不绑定计划'), findsOneWidget);
      expect(find.textContaining('其余按上方预定分配'), findsOneWidget);
      expect(find.text('本分析预定'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('actual allocation mismatch renders a conservation warning', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showWarehouseInboundAllocationDetails(
                context,
                title: '实际去向',
                actual: true,
                sections: [
                  WarehouseInboundAllocationSection(
                    id: 'actual-gap',
                    goodsLabel: 'G-004 · 守恒物料',
                    quantity: 5,
                    unitName: '件',
                    allocations: [
                      _allocation(
                        WarehouseInboundAllocationKind.formalDemand,
                        4,
                      ),
                    ],
                  ),
                ],
              ),
              child: const Text('查看实际去向'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('查看实际去向'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const Key('warehouse-inbound-allocation-conservation-warning'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('差额 1 件 去向待确认'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'two wrong-warehouse reservations retain each original destination',
    (tester) async {
      final projected = warehouseInboundAllocationForWarehouse(
        const [
          WarehouseInboundAllocation(
            kind: WarehouseInboundAllocationKind.exactAnalysis,
            qty: 2,
            targetWarehouseId: 'w1',
            targetWarehouseName: 'W1',
            productName: '产品 A',
            sourceLabel: '分析 A',
            planNo: 'SC-A',
          ),
          WarehouseInboundAllocation(
            kind: WarehouseInboundAllocationKind.sharedClaim,
            qty: 3,
            targetWarehouseId: 'w3',
            targetWarehouseName: 'W3',
            productName: '产品 B',
            sourceLabel: '分析 B',
            planNo: 'SC-B',
          ),
        ],
        5,
        actualWarehouseId: 'w2',
        actualWarehouseName: 'W2',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => SizedBox(
                width: 320,
                child: WarehouseInboundAllocationSummary(
                  allocations: projected,
                  qtyText: _qty,
                  onTap: () => showWarehouseInboundAllocationDetails(
                    context,
                    title: '错仓原预定',
                    sections: [
                      WarehouseInboundAllocationSection(
                        id: 'two-wrong',
                        goodsLabel: 'G-005 · 多仓物料',
                        quantity: 5,
                        unitName: '个',
                        allocations: projected,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('本次全量 5 不绑定计划'));
      await tester.pumpAndSettle();

      expect(find.text('产品 A'), findsOneWidget);
      expect(find.text('产品 B'), findsOneWidget);
      expect(find.textContaining('分析 A · 计划 SC-A · 目标仓 W1'), findsOneWidget);
      expect(find.textContaining('分析 B · 计划 SC-B · 目标仓 W3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

WarehouseInboundAllocation _allocation(
  WarehouseInboundAllocationKind kind,
  double qty,
) => WarehouseInboundAllocation(
  kind: kind,
  qty: qty,
  actualWarehouseId: 'w1',
  actualWarehouseName: 'W1',
  targetWarehouseId: kind == WarehouseInboundAllocationKind.publicStock
      ? null
      : 'w1',
  targetWarehouseName: kind == WarehouseInboundAllocationKind.publicStock
      ? null
      : 'W1',
  analysisId: kind == WarehouseInboundAllocationKind.publicStock
      ? null
      : 'analysis-1',
  analysisMaterialId: kind == WarehouseInboundAllocationKind.publicStock
      ? null
      : 'material-1',
  productCode: 'CP-001',
  productName: '成品一',
  sourceLabel: kind == WarehouseInboundAllocationKind.publicStock
      ? '公共库存'
      : '销售订单 XS-001',
  planNo: kind == WarehouseInboundAllocationKind.formalDemand ? 'SC-001' : null,
  executionSegmentId: kind == WarehouseInboundAllocationKind.formalDemand
      ? 'segment-1'
      : null,
  executionSegmentCode: kind == WarehouseInboundAllocationKind.formalDemand
      ? 'GD-001'
      : null,
  formationStatus: kind == WarehouseInboundAllocationKind.publicStock
      ? '未被生产需求预定，按实际仓公共入库'
      : '继续备料',
);

String _qty(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);
