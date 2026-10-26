import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/production/models/material_transfer_quantity.dart';
import 'package:uten_imp/features/production/models/material_future_transfer.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/features/production/widgets/material_future_transfer_history.dart';
import 'package:uten_imp/features/production/widgets/material_reallocation_dialog.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

void main() {
  testWidgets(
    'future source pages reuse one complete response while retaining exact draft quantities',
    (tester) async {
      final repository = _Repository(sourceCount: 50);
      await _pumpPicker(tester, repository);
      final finder = find.byKey(
        const Key('cross-reallocation-candidates-list'),
      );
      ListView list() => tester.widget<ListView>(finder);
      expect(repository.sourceSnapshotCalls, 1);
      expect(list().childrenDelegate.estimatedChildCount, 41);
      final quantity = find.byKey(
        const Key('future-transfer-qty-allocation-1'),
      );
      await tester.enterText(quantity, '1.2345');
      await tester.enterText(
        find.byKey(const Key('cross-reallocation-reason')),
        '精确在途调拨',
      );
      list().controller!.jumpTo(list().controller!.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(repository.sourceSnapshotCalls, 1);
      expect(list().childrenDelegate.estimatedChildCount, 81);
      final controller = tester.widget<TextFormField>(quantity).controller!;
      expect(controller.text, '1.2345');
      expect(repository.creates, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancel uses exact large remaining and restoration capacities', (
    tester,
  ) async {
    const maximum = '99999999999999.9999';
    final repository = _Repository(exactLimit: maximum);
    await _pumpHistory(tester, repository);
    await tester.tap(
      find.byKey(const Key('future-transfer-cancel-transfer-1')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const Key('future-transfer-cancel-qty')),
          )
          .controller!
          .text,
      maximum,
    );
    expect(find.text('本次恢复原计划 $maximum · 释放公共供给 0'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('future-transfer-cancel-reason')),
      '撤销精确剩余量',
    );
    await tester.tap(find.byKey(const Key('future-transfer-cancel-confirm')));
    await tester.pumpAndSettle();
    expect(repository.cancels.single['qty'], maximum);
  });
  testWidgets('future sources share one exact uncovered demand budget', (
    tester,
  ) async {
    final repository = _Repository();
    await _pumpPicker(tester, repository);
    await tester.tap(
      find.byKey(const Key('future-transfer-candidate-allocation-2')),
    );
    await tester.pumpAndSettle();
    for (final id in ['allocation-1', 'allocation-2']) {
      await tester.enterText(find.byKey(Key('future-transfer-qty-$id')), '60');
    }
    await tester.tap(find.byKey(const Key('cross-reallocation-confirm')));
    await tester.pumpAndSettle();
    expect(repository.creates, isEmpty);
    expect(find.textContaining('超过本计划精确待补量'), findsOneWidget);
  });
  testWidgets(
    'future batch checks its owner again between successful commands',
    (tester) async {
      var current = true;
      var completed = 0;
      final repository = _Repository();
      await _pumpPicker(
        tester,
        repository,
        commandIsCurrent: () => current,
        onCompleted: (_) {
          completed++;
          current = false;
        },
      );
      await tester.tap(
        find.byKey(const Key('future-transfer-candidate-allocation-2')),
      );
      await tester.pumpAndSettle();
      for (final id in ['allocation-1', 'allocation-2']) {
        await tester.enterText(
          find.byKey(Key('future-transfer-qty-$id')),
          '50',
        );
      }
      await tester.tap(find.byKey(const Key('cross-reallocation-confirm')));
      await tester.pumpAndSettle();
      expect(repository.creates, hasLength(1));
      expect(completed, 1);
      expect(find.textContaining('账号、权限或计划状态已变化'), findsOneWidget);
    },
  );
  testWidgets(
    'future batch stops before a second write when its host changes',
    (tester) async {
      var allowed = true;
      var completions = 0;
      final repository = _Repository(onCreate: () => allowed = false);
      await _pumpPicker(
        tester,
        repository,
        commandIsCurrent: () => allowed,
        onCompleted: (_) => completions++,
      );
      await tester.tap(
        find.byKey(const Key('future-transfer-candidate-allocation-2')),
      );
      await tester.pumpAndSettle();
      for (final id in ['allocation-1', 'allocation-2']) {
        await tester.enterText(
          find.byKey(Key('future-transfer-qty-$id')),
          '50',
        );
      }
      await tester.tap(find.byKey(const Key('cross-reallocation-confirm')));
      await tester.pumpAndSettle();
      expect(repository.creates, hasLength(1));
      expect(completions, 0);
      expect(find.textContaining('账号、权限或计划状态已变化'), findsOneWidget);
    },
  );
  testWidgets(
    'an open cancellation cannot write after its host permission is revoked',
    (tester) async {
      final repository = _Repository();
      final writable = ValueNotifier(true);
      addTearDown(writable.dispose);
      await _size(tester, const Size(1000, 850));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: writable,
              builder: (context, allowed, child) =>
                  MaterialFutureTransferHistory(
                    repository: repository,
                    analysisId: 'target-B',
                    materialId: 'target-material',
                    revision: 1,
                    canWrite: allowed,
                    canReplenish: false,
                    onChanged: (_) {},
                    onReplenish: (_) {},
                  ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('future-transfer-cancel-transfer-1')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('future-transfer-cancel-reason')),
        '取消剩余份额',
      );
      writable.value = false;
      await tester.pump();
      await tester.tap(find.byKey(const Key('future-transfer-cancel-confirm')));
      await tester.pumpAndSettle();
      expect(repository.cancels, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'private source allocations remain distinct and transfer only the uncovered hundred',
    (tester) async {
      final repo = _Repository();
      MaterialReallocationCompletion? completed;
      await _pumpPicker(
        tester,
        repo,
        onCompleted: (value) => completed = value,
      );
      expect(
        find.byKey(const Key('future-transfer-candidate-allocation-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('future-transfer-candidate-allocation-2')),
        findsOneWidget,
      );
      // 自动匹配仅覆盖净待补量；改选 allocation-2 验证准确来源。
      await tester.tap(
        find.byKey(const Key('future-transfer-candidate-allocation-1')),
      );
      await tester.tap(
        find.byKey(const Key('future-transfer-candidate-allocation-2')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('future-transfer-qty-allocation-2')),
            )
            .controller!
            .text,
        '100',
      );
      await tester.enterText(
        find.byKey(const Key('cross-reallocation-reason')),
        '加急订单调整',
      );
      await tester.tap(find.byKey(const Key('cross-reallocation-confirm')));
      await tester.pumpAndSettle();
      expect(repo.creates.single['allocation'], 'allocation-2');
      expect(repo.creates.single['qty'], 100);
      expect(repo.creates.single['targetVersion'], 3);
      expect(completed?.sourceAnalysisId, 'source-A');
      expect(completed?.sourceMaterialLineId, 'source-material');
      expect(completed?.futureTransfer, isTrue);
      expect(completed?.idempotencyKey, repo.creates.single['key']);
      expect(repo.lastView?.materials.single.shortageQty, 1000);
    },
  );

  testWidgets(
    'private future late supply is accepted by default and uncertain transfer freezes same intent',
    (tester) async {
      final repo = _Repository(late: true, failCreate: true);
      await _pumpPicker(tester, repo, size: const Size(375, 812));
      // 自动按净待补量选择 allocation-1，晚到默认接受。
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('future-transfer-accept-late')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const Key('cross-reallocation-reason')),
        '同意延后供给',
      );
      await tester.tap(find.byKey(const Key('cross-reallocation-confirm')));
      await tester.pumpAndSettle();
      expect(repo.creates, hasLength(1));
      expect(repo.creates.first['late'], isTrue);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('cross-reallocation-cancel')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('future-transfer-qty-allocation-1')),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(find.byKey(const Key('cross-reallocation-confirm')));
      await tester.pumpAndSettle();
      expect(repo.creates, hasLength(2));
      expect(repo.creates[0], repo.creates[1]);
      expect(repo.creates.first['late'], isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'private records distinguish received stock and source replenishment and cancel only unreceived remainder',
    (tester) async {
      final repo = _Repository();
      MaterialFutureTransferRecord? source;
      ProductionMaterialAnalysisView? changed;
      await _pumpHistory(
        tester,
        repo,
        onReplenish: (record) => source = record,
        onChanged: (view) => changed = view,
      );
      expect(find.text('已实收 30 · 待实收 70 · 已撤销 0'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('future-transfer-replenish-transfer-1')),
      );
      expect(source?.sourceAnalysisId, 'source-A');
      expect(source?.sourceMaterialId, 'source-material');
      await tester.tap(
        find.byKey(const Key('future-transfer-cancel-transfer-1')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('future-transfer-cancel-qty')),
        '71',
      );
      await tester.enterText(
        find.byKey(const Key('future-transfer-cancel-reason')),
        '恢复原计划供给',
      );
      await tester.tap(find.byKey(const Key('future-transfer-cancel-confirm')));
      await tester.pumpAndSettle();
      expect(repo.cancels, isEmpty);
      await tester.enterText(
        find.byKey(const Key('future-transfer-cancel-qty')),
        '20',
      );
      await tester.tap(find.byKey(const Key('future-transfer-cancel-confirm')));
      await tester.pumpAndSettle();
      expect(repo.cancels.single['qty'], 20);
      expect(repo.cancels.single['sourceVersion'], 7);
      expect(repo.cancels.single['targetVersion'], 3);
      expect(changed?.analysisId, 'target-B');
    },
  );

  testWidgets(
    '375px uncertain cancellation locks quantity and retries identical key',
    (tester) async {
      final repo = _Repository(failCancel: true);
      await _pumpHistory(tester, repo, size: const Size(375, 812));
      await tester.tap(
        find.byKey(const Key('future-transfer-cancel-transfer-1')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('future-transfer-cancel-reason')),
        '恢复原计划供给',
      );
      await tester.tap(find.byKey(const Key('future-transfer-cancel-confirm')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const Key('future-transfer-cancel-qty')),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('future-transfer-cancel-close')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('future-transfer-cancel-confirm')));
      await tester.pumpAndSettle();
      expect(repo.cancels, hasLength(2));
      expect(repo.cancels[0], repo.cancels[1]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'view-only owner sees outgoing history without write actions and query failure is not zero',
    (tester) async {
      final repo = _Repository(outbound: true, failRecords: true);
      await _pumpHistory(tester, repo, canWrite: false);
      expect(find.textContaining('查询暂不可用'), findsOneWidget);
      expect(find.text('暂无专属在途调拨记录'), findsNothing);
      await tester.tap(find.byKey(const Key('future-transfer-history-retry')));
      await tester.pumpAndSettle();
      expect(find.textContaining('已让出专属在途 100'), findsOneWidget);
      expect(
        find.byKey(const Key('future-transfer-cancel-transfer-1')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'failed private source warns without removing the promised remainder or cancellation entry',
    (tester) async {
      final repo = _Repository(failedSource: true);
      await _pumpHistory(tester, repo);
      expect(
        find.byKey(const Key('future-transfer-supply-warning-transfer-1')),
        findsOneWidget,
      );
      expect(find.text('原供给终检失败，尚有 70 未兑现；请补供或撤销未实收份额'), findsOneWidget);
      expect(find.text('已实收 30 · 待实收 70 · 已撤销 0'), findsOneWidget);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('future-transfer-cancel-transfer-1')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'cancelling after donor replacement explicitly releases only the excess to public supply',
    (tester) async {
      final repo = _Repository(restoreQty: 20);
      await _pumpHistory(tester, repo);
      await tester.tap(
        find.byKey(const Key('future-transfer-cancel-transfer-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('本次恢复原计划 20 · 释放公共供给 50'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('future-transfer-cancel-reason')),
        '原计划已有补单，释放余量',
      );
      await tester.tap(find.byKey(const Key('future-transfer-cancel-confirm')));
      await tester.pumpAndSettle();
      expect(repo.cancels, isEmpty);
      await tester.enterText(
        find.byKey(const Key('future-transfer-cancel-qty')),
        '40',
      );
      await tester.pumpAndSettle();
      expect(find.text('本次恢复原计划 20 · 释放公共供给 20'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('future-transfer-cancel-public-release')),
      );
      await tester.tap(find.byKey(const Key('future-transfer-cancel-confirm')));
      await tester.pumpAndSettle();
      expect(repo.cancels.single['qty'], 40);
      expect(repo.cancels.single['acceptPublicRelease'], isTrue);
    },
  );
}

Future<void> _size(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpPicker(
  WidgetTester tester,
  _Repository repo, {
  Size size = const Size(1200, 900),
  ValueChanged<MaterialReallocationCompletion>? onCompleted,
  bool Function()? commandIsCurrent,
}) async {
  await _size(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showMaterialReallocationDialog(
              context: context,
              repository: repo,
              sourceAnalysis: _view,
              sourceMaterial: _material,
              sourceProductLabel: '接受计划 B',
              qtyText: (qty) => qty?.toStringAsFixed(0) ?? '—',
              futureTransfer: true,
              onCompleted: onCompleted,
              commandIsCurrent: commandIsCurrent,
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

Future<void> _pumpHistory(
  WidgetTester tester,
  _Repository repo, {
  Size size = const Size(1000, 850),
  bool canWrite = true,
  ValueChanged<MaterialFutureTransferRecord>? onReplenish,
  ValueChanged<ProductionMaterialAnalysisView>? onChanged,
}) async {
  await _size(tester, size);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MaterialFutureTransferHistory(
            repository: repo,
            analysisId: 'target-B',
            materialId: 'target-material',
            revision: 1,
            canWrite: canWrite,
            canReplenish: true,
            onChanged: onChanged ?? (_) {},
            onReplenish: onReplenish ?? (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _material = ProductionMaterialAnalysisMaterial(
  materialLineId: 'target-material',
  analysisLineId: 'product-B',
  goodsId: 'goods-1',
  goodsName: '手机面板',
  requiredQty: 1000,
  shortageQty: 1000,
  additionalSupplyRecommendedQty: 100,
  sourceConfirmed: MaterialSupplyRoute.buy,
  actionable: true,
);
const _view = ProductionMaterialAnalysisView(
  analysisId: 'target-B',
  version: 3,
  fingerprint: 'target-fingerprint',
  warehouseId: 'warehouse',
  materials: [_material],
);

class _Repository extends ProductionPlanRepository {
  _Repository({
    this.late = false,
    this.sourceCount = 2,
    this.failCreate = false,
    this.failCancel = false,
    this.outbound = false,
    this.failRecords = false,
    this.restoreQty,
    this.failedSource = false,
    this.onCreate,
    this.exactLimit,
  }) : super(ApiClient(Dio()));
  final bool late;
  final int sourceCount;
  int sourceSnapshotCalls = 0;
  bool failCreate;
  bool failCancel;
  final bool outbound;
  bool failRecords;
  final double? restoreQty;
  final bool failedSource;
  final VoidCallback? onCreate;
  final String? exactLimit;
  final creates = <Map<String, Object>>[];
  final cancels = <Map<String, Object>>[];
  ProductionMaterialAnalysisView? lastView;
  @override
  Future<List<MaterialFutureTransferSource>>
  materialFutureTransferSourceSnapshot({
    required String targetAnalysisId,
    required String targetMaterialId,
    bool Function()? isCurrent,
  }) async {
    sourceSnapshotCalls++;
    return (await materialFutureTransferSources(
      targetAnalysisId: targetAnalysisId,
      targetMaterialId: targetMaterialId,
    )).items;
  }

  @override
  Future<PagedResult<MaterialFutureTransferSource>>
  materialFutureTransferSources({
    required String targetAnalysisId,
    required String targetMaterialId,
    int page = 1,
    int size = 20,
    String keyword = '',
  }) async => PagedResult(
    items: [
      for (final id in [for (var i = 1; i <= sourceCount; i++) 'allocation-$i'])
        MaterialFutureTransferSource(
          sourceAllocationId: id,
          sourceAnalysisId: 'source-A',
          sourceMaterialId: 'source-material',
          sourceLabel: '原计划 A',
          availableQty: 500,
          receivedQty: 0,
          sourceVersion: 7,
          sourceFingerprint: 'a' * 64,
          targetVersion: 4,
          targetFingerprint: 'new-target-fingerprint',
          targetUncoveredQty: 100,
          lateOrUnknown: late,
        ),
    ],
    page: page,
    size: size,
    total: 2,
    totalPages: 1,
  );
  @override
  Future<ProductionMaterialAnalysisView> createMaterialFutureTransfer({
    required ProductionMaterialAnalysisView targetAnalysis,
    required String targetMaterialId,
    required MaterialFutureTransferSource source,
    required Object qty,
    required bool allowLateSupply,
    required String reason,
    required String idempotencyKey,
  }) async {
    creates.add({
      'allocation': source.sourceAllocationId,
      'qty': materialTransferWire(qty),
      'late': allowLateSupply,
      'key': idempotencyKey,
      'targetVersion': targetAnalysis.version,
    });
    if (failCreate) {
      failCreate = false;
      throw NetworkTimeoutException();
    }
    onCreate?.call();
    return lastView = _view;
  }

  @override
  Future<List<MaterialFutureTransferRecord>> materialFutureTransfers({
    required String analysisId,
    String? materialId,
  }) async {
    if (failRecords) {
      failRecords = false;
      throw NetworkException('查询暂不可用，进度未知');
    }
    return [
      MaterialFutureTransferRecord(
        id: 'transfer-1',
        sourceAllocationId: 'allocation-1',
        sourceAnalysisId: 'source-A',
        sourceMaterialId: 'source-material',
        targetAnalysisId: 'target-B',
        targetMaterialId: 'target-material',
        qty: exactLimit == null ? 100 : double.parse(exactLimit!),
        cancelledQty: 0,
        receivedQty: exactLimit == null ? 30 : 0,
        remainingQty: exactLimit == null ? 70 : double.parse(exactLimit!),
        status: 'PARTIAL',
        sourceVersion: 7,
        sourceFingerprint: 'source-fingerprint',
        targetVersion: 3,
        targetFingerprint: 'target-fingerprint',
        direction: outbound ? 'OUT' : 'IN',
        sourceLabel: '原计划 A',
        targetLabel: '接受计划 B',
        canCancel: true,
        quantityFactsExact: exactLimit == null
            ? const {}
            : {
                'qty': exactLimit!,
                'receivedQty': '0',
                'remainingQty': exactLimit!,
                'cancelableQty': exactLimit!,
                'cancelRestoreToSourceQty': exactLimit!,
              },
        cancelRestoreToSourceQty: restoreQty,
        cancelPublicReleaseQty: restoreQty == null ? 0 : 70 - restoreQty!,
        sourceSupplyShortfallQty: failedSource ? 70 : 0,
        supplyWarning: failedSource ? '原供给终检失败，尚有 70 未兑现；请补供或撤销未实收份额' : null,
      ),
    ];
  }

  @override
  Future<ProductionMaterialAnalysisView> cancelMaterialFutureTransfer({
    required String analysisId,
    required MaterialFutureTransferRecord transfer,
    required Object qty,
    required String reason,
    required String idempotencyKey,
    bool acceptPublicRelease = false,
  }) async {
    cancels.add({
      'qty': materialTransferWire(qty),
      'key': idempotencyKey,
      'sourceVersion': transfer.sourceVersion,
      'targetVersion': transfer.targetVersion,
      'acceptPublicRelease': acceptPublicRelease,
    });
    if (failCancel) {
      failCancel = false;
      throw NetworkTimeoutException();
    }
    return _view;
  }
}
