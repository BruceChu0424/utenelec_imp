import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/providers/production_department_provider.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/core/theme/uten_colors.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  testWidgets('fresh analysis exposes audited manual source types', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {Perm.productionMaterialAnalysisManage},
      seeded: false,
    );

    expect(find.text('手工计划（返工 / 试制 / 样品 / 备库）'), findsOneWidget);
    expect(find.text('物料分析记录'), findsOneWidget);
    expect(find.text('生产计划历史'), findsOneWidget);
    expect(find.byKey(const Key('manual-source-ref')), findsOneWidget);
    expect(find.text('同一需求请始终使用同一个编号'), findsOneWidget);
    expect(find.byKey(const Key('manual-source-goods')), findsOneWidget);
    expect(find.byKey(const Key('manual-source-reason')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('manual-source-')));
    await tester.pumpAndSettle();
    expect(find.text('返工'), findsOneWidget);
    expect(find.text('试制'), findsOneWidget);
    expect(find.text('样品'), findsOneWidget);
    expect(find.text('备库'), findsOneWidget);
    expect(find.text('其他'), findsOneWidget);
  });

  testWidgets(
    'desktop sales candidates support row and tri-state header selection',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1400, 900),
        permissions: const {Perm.productionMaterialAnalysisManage},
        seeded: false,
        responseOverride: (request) =>
            request.path.endsWith('/sales-candidates')
            ? _salesCandidatesJson()
            : null,
      );

      final table = find.byKey(const Key('material-analysis-candidate-table'));
      final checkboxes = find.descendant(
        of: table,
        matching: find.byType(Checkbox),
      );
      expect(table, findsOneWidget);
      expect(checkboxes, findsNWidgets(3));
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isFalse);

      await tester.tap(checkboxes.at(0));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isTrue);
      expect(find.text('已选 2 个产品 · 数量已预填，只需修改例外'), findsOneWidget);
      expect(find.byKey(const Key('source-qty-sales-line-a')), findsOneWidget);
      expect(find.byKey(const Key('source-qty-sales-line-b')), findsOneWidget);

      await tester.tap(checkboxes.at(1));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isNull);
      expect(find.text('已选 1 个产品 · 数量已预填，只需修改例外'), findsOneWidget);

      // Tri-state header follows Checkbox semantics: partial -> clear page,
      // then unchecked -> select all, then checked -> clear again.
      await tester.tap(checkboxes.at(0));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isFalse);
      await tester.tap(checkboxes.at(0));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isTrue);
      await tester.tap(checkboxes.at(0));
      await tester.pump();
      expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isFalse);
      expect(find.textContaining('已选 '), findsNothing);
    },
  );

  testWidgets(
    'compact sales candidates paginate and preserve cross-page selection',
    (tester) async {
      final requestedPages = <int>[];
      await _pumpPage(
        tester,
        size: const Size(375, 900),
        permissions: const {Perm.productionMaterialAnalysisManage},
        seeded: false,
        responseOverride: (request) {
          if (!request.path.endsWith('/sales-candidates')) return null;
          final page = (request.queryParameters['page'] as num?)?.toInt() ?? 1;
          requestedPages.add(page);
          return _pagedSalesCandidatesJson(page);
        },
      );

      final mobileList = find.byKey(
        const Key('material-analysis-candidate-mobile-list'),
      );
      expect(
        find.descendant(of: mobileList, matching: find.byType(ListView)),
        findsNothing,
      );
      expect(find.text('手机候选产品 A'), findsOneWidget);
      expect(find.text('上一页'), findsOneWidget);
      expect(find.text('下一页'), findsOneWidget);
      expect(find.textContaining('第 1 / 2 页'), findsOneWidget);

      final candidateCheckbox = find.descendant(
        of: mobileList,
        matching: find.byType(Checkbox),
      );
      await tester.ensureVisible(candidateCheckbox);
      await tester.tap(candidateCheckbox);
      await tester.pump();
      final editSelectedQty = find.byKey(
        const Key('material-compact-edit-selected-qty'),
      );
      expect(
        find.byKey(const Key('source-qty-mobile-sales-line-a')),
        findsNothing,
      );
      await tester.ensureVisible(editSelectedQty);
      await tester.tap(editSelectedQty);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('material-compact-selected-qty-list')),
        findsOneWidget,
      );
      final firstQty = find.byKey(const Key('source-qty-mobile-sales-line-a'));
      expect(firstQty, findsOneWidget);
      expect(tester.widget<TextField>(firstQty).controller?.text, '8');
      await tester.enterText(firstQty, '9');
      await tester.tap(find.text('数量核对完成'));
      await tester.pumpAndSettle();
      expect(firstQty, findsNothing);

      await tester.tap(find.byKey(const Key('material-candidate-next-page')));
      await tester.pumpAndSettle();
      expect(find.text('手机候选产品 B'), findsOneWidget);
      expect(find.textContaining('第 2 / 2 页'), findsOneWidget);
      expect(
        find.byKey(const Key('source-qty-mobile-sales-line-a')),
        findsNothing,
      );

      await tester.ensureVisible(candidateCheckbox);
      await tester.tap(candidateCheckbox);
      await tester.pump();
      expect(tester.widget<Checkbox>(candidateCheckbox).value, isTrue);
      expect(find.text('已选 2 个销售产品'), findsOneWidget);
      expect(
        find.byKey(const Key('source-qty-mobile-sales-line-b')),
        findsNothing,
      );

      await tester.ensureVisible(editSelectedQty);
      await tester.tap(editSelectedQty);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(firstQty).controller?.text, '9');
      expect(
        find.byKey(const Key('source-qty-mobile-sales-line-b')),
        findsOneWidget,
      );
      await tester.tap(find.text('数量核对完成'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: mobileList, matching: find.byType(ListView)),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('material-candidate-prev-page')));
      await tester.pumpAndSettle();
      expect(find.text('手机候选产品 A'), findsOneWidget);
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: mobileList, matching: find.byType(Checkbox)),
            )
            .value,
        isTrue,
      );
      expect(requestedPages, containsAllInOrder([1, 2, 1]));
    },
  );

  testWidgets('seeded manual analysis sends the stable demand reference', (
    tester,
  ) async {
    final harness = await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {Perm.productionMaterialAnalysisManage},
      sources: const [
        MaterialAnalysisSourceInput(
          sourceType: 'REWORK',
          sourceRef: 'RW-20260808-001',
          goodsId: 'goods-1',
          unitId: 'unit-1',
          requestedQty: 3,
          sourceReason: '客诉返工',
        ),
      ],
    );

    final request = harness.requests.singleWhere(
      (value) => value.path == '/production/material-analyses/preview',
    );
    expect((request.data as Map<String, dynamic>)['sources'], [
      {
        'sourceType': 'REWORK',
        'sourceRef': 'RW-20260808-001',
        'goodsId': 'goods-1',
        'unitId': 'unit-1',
        'requestedQty': 3.0,
        'sourceReason': '客诉返工',
      },
    ]);
  });

  testWidgets(
    'existing writable analysis auto-refreshes from the full persisted source set',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {Perm.productionMaterialAnalysisManage},
        allowedActions: const ['REFRESH'],
        analysisId: 'analysis-1',
      );

      expect(
        harness.requests.where(
          (request) =>
              request.method == 'GET' &&
              request.path == '/production/material-analyses/analysis-1',
        ),
        hasLength(1),
      );
      final refresh = harness.requests.singleWhere(
        (request) =>
            request.method == 'POST' &&
            request.path == '/production/material-analyses/preview',
      );
      final sources =
          (refresh.data! as Map<String, dynamic>)['sources'] as List;
      // The seed deliberately contains only one selected source. Reopening the
      // persisted joint analysis must refresh both original user sources and
      // must not submit the system-derived MAKE_COMPONENT child.
      expect(sources, hasLength(2));
      expect(
        sources.any(
          (source) => (source as Map).containsKey('salesOrderItemId'),
        ),
        isTrue,
      );
      expect(
        sources.any((source) => (source as Map)['sourceType'] == 'STOCK'),
        isTrue,
      );
      expect(find.text('第二测试产品'), findsOneWidget);
    },
  );

  testWidgets(
    'resumed VIEW-only analysis never mutates its persisted snapshot',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {Perm.productionMaterialAnalysisManage},
        allowedActions: const ['VIEW'],
        analysisId: 'analysis-1',
        seeded: false,
      );
      expect(
        harness.requests.where(
          (request) =>
              request.method == 'POST' &&
              request.path == '/production/material-analyses/preview',
        ),
        isEmpty,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.refresh_rounded),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'accept-all-suggested-routes bulk-confirms concrete suggestions without reason',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
        },
        allowedActions: const ['CONFIRM_ROUTES'],
        analysisId: 'analysis-1',
        seeded: false,
      );
      // Same material on two BOM paths is now two independent decisions.
      final acceptButton = find.text('采纳建议路线（2）');
      expect(acceptButton, findsOneWidget);
      await tester.ensureVisible(acceptButton);
      await tester.pumpAndSettle();
      await tester.tap(acceptButton);
      await tester.pumpAndSettle();

      final routeRequest = harness.requests.singleWhere(
        (request) => request.method == 'PUT',
      );
      expect(
        routeRequest.path,
        '/production/material-analyses/analysis-1/routes',
      );
      final decisions =
          (routeRequest.data! as Map<String, dynamic>)['decisions'] as List;
      expect(decisions, hasLength(2));
      expect(
        decisions
            .cast<Map<String, dynamic>>()
            .map((decision) => decision['actionGroupKey'])
            .toSet(),
        {'action-material-path-1', 'action-material-path-2'},
      );
      for (final decision in decisions.cast<Map<String, dynamic>>()) {
        expect(decision['route'], 'BUY');
        // Accepting the suggestion (route == suggestion) needs no reason.
        expect(decision.containsKey('reason'), isFalse);
      }
    },
  );

  testWidgets(
    '501 suggested routes are saved as 500 plus 1 with refreshed CAS facts',
    (tester) async {
      var routeResponse = 0;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
        },
        allowedActions: const ['CONFIRM_ROUTES'],
        analysisJson: _bulkRouteAnalysisJson(
          count: 501,
          allowedActions: const ['CONFIRM_ROUTES'],
        ),
        responseOverride: (request) {
          if (!request.path.endsWith('/routes')) return null;
          routeResponse++;
          return _bulkRouteAnalysisJson(
            count: 501,
            allowedActions: const ['CONFIRM_ROUTES'],
            version: 3 + routeResponse,
            fingerprintChar: routeResponse == 1 ? 'b' : 'c',
            confirmedCount: routeResponse == 1 ? 500 : 501,
          );
        },
      );

      final accept = find.text('采纳建议路线（501）');
      expect(accept, findsOneWidget);
      await tester.tap(accept);
      await tester.pumpAndSettle();

      final writes = harness.requests
          .where(
            (request) =>
                request.method == 'PUT' && request.path.endsWith('/routes'),
          )
          .toList(growable: false);
      expect(writes, hasLength(2));
      final first = writes[0].data! as Map<String, dynamic>;
      final second = writes[1].data! as Map<String, dynamic>;
      expect(first['version'], 3);
      expect(first['fingerprint'], 'a' * 64);
      expect(first['decisions'], hasLength(500));
      expect(second['version'], 4);
      expect(second['fingerprint'], 'b' * 64);
      expect(second['decisions'], hasLength(1));
      expect(
        ((second['decisions'] as List).single as Map)['actionGroupKey'],
        'bulk-action-501',
      );
    },
  );

  testWidgets(
    'route retry reuses the exact timed-out second chunk idempotency key',
    (tester) async {
      var routeAttempt = 0;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
        },
        allowedActions: const ['CONFIRM_ROUTES'],
        analysisJson: _bulkRouteAnalysisJson(
          count: 501,
          allowedActions: const ['CONFIRM_ROUTES'],
        ),
        errorOverride: (request) {
          if (!request.path.endsWith('/routes')) return null;
          routeAttempt++;
          if (routeAttempt != 2) return null;
          return DioException(
            requestOptions: request,
            type: DioExceptionType.receiveTimeout,
            message: '服务端已成功，但客户端等待超时',
          );
        },
        responseOverride: (request) {
          if (!request.path.endsWith('/routes')) return null;
          return _bulkRouteAnalysisJson(
            count: 501,
            allowedActions: const ['CONFIRM_ROUTES'],
            version: routeAttempt == 1 ? 4 : 5,
            fingerprintChar: routeAttempt == 1 ? 'b' : 'c',
            confirmedCount: routeAttempt == 1 ? 500 : 501,
          );
        },
      );

      await tester.tap(find.text('采纳建议路线（501）'));
      await tester.pumpAndSettle();
      expect(find.text('确认路线（1）'), findsOneWidget);

      await tester.tap(find.text('确认路线（1）'));
      await tester.pumpAndSettle();

      final writes = harness.requests
          .where(
            (request) =>
                request.method == 'PUT' && request.path.endsWith('/routes'),
          )
          .toList(growable: false);
      expect(writes, hasLength(3));
      final failedChunk = writes[1].data! as Map<String, dynamic>;
      final retriedChunk = writes[2].data! as Map<String, dynamic>;
      expect(failedChunk['version'], 4);
      expect(failedChunk['fingerprint'], 'b' * 64);
      expect(failedChunk['decisions'], hasLength(1));
      expect(retriedChunk['version'], failedChunk['version']);
      expect(retriedChunk['fingerprint'], failedChunk['fingerprint']);
      expect(retriedChunk['decisions'], failedChunk['decisions']);
      expect(retriedChunk['idempotencyKey'], failedChunk['idempotencyKey']);
    },
  );

  testWidgets(
    '501 selected BUY nodes notify as 500 plus 1 with refreshed CAS facts',
    (tester) async {
      var notifyResponse = 0;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisNotify,
        },
        allowedActions: const ['NOTIFY_SUPPLY'],
        analysisJson: _bulkRouteAnalysisJson(
          count: 501,
          allowedActions: const ['NOTIFY_SUPPLY'],
          confirmedCount: 501,
        ),
        responseOverride: (request) {
          if (!request.path.endsWith('/notify')) return null;
          notifyResponse++;
          return _bulkRouteAnalysisJson(
            count: 501,
            allowedActions: const ['NOTIFY_SUPPLY'],
            version: 3 + notifyResponse,
            fingerprintChar: notifyResponse == 1 ? 'b' : 'c',
            confirmedCount: 501,
            notifiedCount: notifyResponse == 1 ? 500 : 501,
          );
        },
      );

      final selectAll = find.byKey(
        const ValueKey('material-route-select-all-BUY'),
      );
      await tester.scrollUntilVisible(
        selectAll,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(selectAll);
      await tester.pump();
      expect(find.text('提交采购需求（501）'), findsOneWidget);
      await tester.tap(find.text('提交采购需求（501）'));
      await tester.pumpAndSettle();

      final writes = harness.requests
          .where(
            (request) =>
                request.method == 'POST' && request.path.endsWith('/notify'),
          )
          .toList(growable: false);
      expect(writes, hasLength(2));
      final first = writes[0].data! as Map<String, dynamic>;
      final second = writes[1].data! as Map<String, dynamic>;
      expect(first['version'], 3);
      expect(first['fingerprint'], 'a' * 64);
      expect(first['actionGroupKeys'], hasLength(500));
      expect(second['version'], 4);
      expect(second['fingerprint'], 'b' * 64);
      expect(second['actionGroupKeys'], ['bulk-action-501']);
    },
  );

  testWidgets(
    'notify retry reuses the exact timed-out second chunk idempotency key',
    (tester) async {
      var notifyAttempt = 0;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisNotify,
        },
        allowedActions: const ['NOTIFY_SUPPLY'],
        analysisJson: _bulkRouteAnalysisJson(
          count: 501,
          allowedActions: const ['NOTIFY_SUPPLY'],
          confirmedCount: 501,
        ),
        errorOverride: (request) {
          if (!request.path.endsWith('/notify')) return null;
          notifyAttempt++;
          if (notifyAttempt != 2) return null;
          return DioException(
            requestOptions: request,
            type: DioExceptionType.receiveTimeout,
            message: '服务端已成功，但客户端等待超时',
          );
        },
        responseOverride: (request) {
          if (!request.path.endsWith('/notify')) return null;
          return _bulkRouteAnalysisJson(
            count: 501,
            allowedActions: const ['NOTIFY_SUPPLY'],
            version: notifyAttempt == 1 ? 4 : 5,
            fingerprintChar: notifyAttempt == 1 ? 'b' : 'c',
            confirmedCount: 501,
            notifiedCount: notifyAttempt == 1 ? 500 : 501,
          );
        },
      );

      final selectAll = find.byKey(
        const ValueKey('material-route-select-all-BUY'),
      );
      await tester.scrollUntilVisible(
        selectAll,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(selectAll);
      await tester.pump();
      await tester.tap(find.text('提交采购需求（501）'));
      await tester.pumpAndSettle();
      expect(find.text('提交采购需求（1）'), findsOneWidget);

      await tester.tap(find.text('提交采购需求（1）'));
      await tester.pumpAndSettle();

      final writes = harness.requests
          .where(
            (request) =>
                request.method == 'POST' && request.path.endsWith('/notify'),
          )
          .toList(growable: false);
      expect(writes, hasLength(3));
      final failedChunk = writes[1].data! as Map<String, dynamic>;
      final retriedChunk = writes[2].data! as Map<String, dynamic>;
      expect(failedChunk['version'], 4);
      expect(failedChunk['fingerprint'], 'b' * 64);
      expect(failedChunk['actionGroupKeys'], hasLength(1));
      expect(retriedChunk['version'], failedChunk['version']);
      expect(retriedChunk['fingerprint'], failedChunk['fingerprint']);
      expect(retriedChunk['target'], failedChunk['target']);
      expect(retriedChunk['actionGroupKeys'], failedChunk['actionGroupKeys']);
      expect(retriedChunk['idempotencyKey'], failedChunk['idempotencyKey']);
    },
  );

  testWidgets(
    'makeComponent card shows parent assembly and ready items sort first',
    (tester) async {
      final json = _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']);
      final products = json['products']! as List<dynamic>;
      // Top product is blocked (readyNowQty 0); a self-make sub-assembly is
      // plan-ready and linked back to it.
      (products[0] as Map<String, dynamic>)
        ..['goodsName'] = '顶级插座'
        ..['readyNowQty'] = 0;
      products.add({
        'analysisLineId': 'make-comp-1',
        'sourceType': 'MAKE_COMPONENT',
        'goodsCode': 'SUB-A',
        'goodsName': '自制子件A',
        'parentAnalysisLineId': 'product-line-1',
        'parentGoodsName': '顶级插座',
        'requestedQty': 10,
        'remainingQty': 10,
        'readyNowQty': 6,
        'readinessRatio': 0.6,
        'productionBomPolicy': 'DIRECT_MAKE',
        'missingBom': false,
        'bomOverrideRequired': false,
        'hasActiveBom': false,
        'allocationPriority': 2,
      });
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: json,
      );

      // The self-make card surfaces the parent assembly it feeds into.
      expect(find.textContaining('用于组装 顶级插座'), findsOneWidget);
      // Bottom-up ordering: the plan-ready sub-assembly renders before the
      // still-blocked top product (Wrap lays children out left-to-right).
      final subAssembly = find.byKey(
        const ValueKey('material-analysis-product-make-comp-1'),
      );
      final topProduct = find.byKey(
        const ValueKey('material-analysis-product-product-line-1'),
      );
      expect(subAssembly, findsOneWidget);
      expect(topProduct, findsOneWidget);
      expect(
        tester.getTopLeft(subAssembly).dx,
        lessThan(tester.getTopLeft(topProduct).dx),
      );
      await tester.tap(
        find.byKey(
          const ValueKey('material-analysis-product-select-make-comp-1'),
        ),
      );
      await tester.pump();
      expect(find.text('安排子件生产（1）'), findsOneWidget);
    },
  );

  testWidgets(
    'BOM paths stay independent and suggested route can be adopted inline',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisGenerate,
        },
        allowedActions: const ['CONFIRM_ROUTES'],
      );

      final firstRow = find.byKey(
        const ValueKey('material-bom-node-material-path-1'),
      );
      final secondRow = find.byKey(
        const ValueKey('material-bom-node-material-path-2'),
      );
      await tester.scrollUntilVisible(
        firstRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(firstRow, findsOneWidget);
      // 节点行新增备料进度条后行高增加，第二行可能落在 SliverList 懒构建
      // 窗口之外；滚动到它出现再断言。不改变“两条路径各自独立”的验证目标。
      await tester.scrollUntilVisible(
        secondRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(secondRow, findsOneWidget);
      expect(find.textContaining('涉及 2 条路径'), findsNothing);
      expect(
        find.descendant(
          of: firstRow,
          matching: find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
        ),
        findsNothing,
      );
      expect(find.textContaining('测试产品 → 组件 A'), findsNothing);
      final details = find.byKey(
        const ValueKey('material-node-details-toggle-material-path-1'),
      );
      final semantics = tester.ensureSemantics();
      expect(tester.getSize(details).height, greaterThanOrEqualTo(48));
      expect(tester.getSemantics(details).label, contains('展开共享紧固件详情'));
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(details).label, contains('收起共享紧固件详情'));
      semantics.dispose();
      final firstDropdown = find.descendant(
        of: firstRow,
        matching: find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
      );
      final dropdown = tester
          .widget<DropdownButtonFormField<MaterialSupplyRoute>>(firstDropdown);
      expect(dropdown.initialValue, isNull);
      expect(find.textContaining('路径：测试产品'), findsOneWidget);
      final adopt = find.byKey(
        const ValueKey('material-adopt-route-material-path-1'),
      );
      expect(
        find.descendant(of: firstRow, matching: find.text('采用采购')),
        findsOneWidget,
      );
      await tester.ensureVisible(adopt);
      await tester.pumpAndSettle();
      await tester.tap(adopt);
      await tester.pumpAndSettle();

      final routeRequest = harness.requests.singleWhere(
        (request) => request.method == 'PUT',
      );
      expect(
        routeRequest.path,
        '/production/material-analyses/analysis-1/routes',
      );
      expect((routeRequest.data! as Map<String, dynamic>)['decisions'], [
        {'actionGroupKey': 'action-material-path-1', 'route': 'BUY'},
      ]);
    },
  );

  testWidgets(
    'unconfirmed route gates require explicit adoption and never write implicitly',
    (tester) async {
      const actions = ['CONFIRM_ROUTES', 'NOTIFY_SUPPLY'];

      Map<String, dynamic> routeState({
        required bool buyConfirmed,
        required bool subcontractConfirmed,
      }) {
        final json = _analysisJson(actions);
        final materials = (json['flatMaterials'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        final buy = materials.firstWhere(
          (material) => material['materialLineId'] == 'material-path-1',
        );
        final subcontract = materials.firstWhere(
          (material) => material['materialLineId'] == 'material-path-2',
        );
        subcontract['sourceSuggestion'] = 'SUBCONTRACT';
        if (buyConfirmed) {
          buy
            ..['sourceConfirmed'] = 'BUY'
            ..['routeConfirmed'] = true;
        }
        if (subcontractConfirmed) {
          subcontract
            ..['sourceConfirmed'] = 'SUBCONTRACT'
            ..['routeConfirmed'] = true;
        }
        return json;
      }

      var routeWrites = 0;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
        },
        allowedActions: actions,
        analysisJson: routeState(
          buyConfirmed: false,
          subcontractConfirmed: false,
        ),
        responseOverride: (request) {
          if (!request.path.endsWith('/routes')) return null;
          routeWrites++;
          return routeState(
            buyConfirmed: true,
            subcontractConfirmed: routeWrites > 1,
          );
        },
      );

      final buyGate = find.byKey(
        const ValueKey('material-bom-gate-material-path-1'),
      );
      await tester.scrollUntilVisible(
        buyGate,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.getSize(buyGate).height, greaterThanOrEqualTo(48));
      expect(
        find.descendant(of: buyGate, matching: find.text('先确认路线')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: buyGate, matching: find.byType(Checkbox)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('material-bom-node-material-path-1')),
          matching: find.byType(Checkbox),
        ),
        findsNothing,
      );
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        isEmpty,
      );

      await tester.tap(
        find.byKey(const ValueKey('material-adopt-route-material-path-1')),
      );
      await tester.pumpAndSettle();
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        hasLength(1),
      );
      expect(buyGate, findsNothing);
      final buyCheckbox = find.byKey(
        const ValueKey('material-bom-select-material-path-1'),
      );
      expect(
        find.descendant(of: buyCheckbox, matching: find.byType(Checkbox)),
        findsOneWidget,
      );
      await tester.tap(buyCheckbox);
      await tester.pump();
      expect(find.text('提交采购需求（1）'), findsOneWidget);

      final subcontractGate = find.byKey(
        const ValueKey('material-bom-gate-material-path-2'),
      );
      await tester.ensureVisible(subcontractGate);
      expect(tester.getSize(subcontractGate).height, greaterThanOrEqualTo(48));
      expect(
        find.descendant(of: subcontractGate, matching: find.text('先确认路线')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: subcontractGate, matching: find.byType(Checkbox)),
        findsNothing,
      );
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        hasLength(1),
      );

      await tester.tap(
        find.byKey(const ValueKey('material-adopt-route-material-path-2')),
      );
      await tester.pumpAndSettle();
      // Refreshing the second route must preserve the already selected BUY
      // node instead of silently dropping a planner's earlier selection.
      expect(find.text('提交采购需求（1）'), findsOneWidget);
      expect(
        harness.requests.where((request) => request.method == 'PUT'),
        hasLength(2),
      );
      expect(subcontractGate, findsNothing);
      final subcontractCheckbox = find.byKey(
        const ValueKey('material-bom-select-material-path-2'),
      );
      expect(
        find.descendant(
          of: subcontractCheckbox,
          matching: find.byType(Checkbox),
        ),
        findsOneWidget,
      );
      await tester.tap(subcontractCheckbox);
      await tester.pump();
      expect(find.text('提交委外需求（1）'), findsOneWidget);
    },
  );

  testWidgets(
    'route override requires a reason and cancel keeps empty default',
    (tester) async {
      final json = _analysisJson(const ['CONFIRM_ROUTES']);
      json['flatMaterials'] = [
        _materialJson(
          id: 'material-path-1',
          level: 2,
          path: ['测试产品', '组件 A', '共享紧固件'],
          routeConfirmed: false,
        ),
      ];
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
        },
        allowedActions: const ['CONFIRM_ROUTES'],
        analysisJson: json,
      );

      await _chooseRoute(tester, '自制');
      expect(find.byKey(const Key('material-route-reason')), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('确认路线（0）'), findsNothing);
      expect(
        tester
            .widget<DropdownButtonFormField<MaterialSupplyRoute>>(
              find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
            )
            .initialValue,
        isNull,
      );

      await _chooseRoute(tester, '自制');
      await tester.enterText(
        find.byKey(const Key('material-route-reason')),
        '交期紧急，改为车间自制',
      );
      await tester.tap(find.text('确认路线'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认路线（1）'));
      await tester.pumpAndSettle();

      final routeRequest = harness.requests.singleWhere(
        (request) => request.method == 'PUT',
      );
      expect(routeRequest.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'decisions': [
          {
            'actionGroupKey': 'action-material-path-1',
            'route': 'MAKE',
            'reason': '交期紧急，改为车间自制',
          },
        ],
      });
    },
  );

  testWidgets(
    'allowedActions VIEW blocks every server write despite local permissions',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
          Perm.productionPlanApprove,
          Perm.productionMaterialAnalysisReallocate,
        },
        allowedActions: const ['VIEW'],
      );

      expect(find.byKey(const Key('material-analysis-generate')), findsNothing);
      expect(find.text('生成并批准'), findsNothing);
      expect(
        find.byKey(const Key('material-analysis-priority-edit')),
        findsNothing,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.refresh_rounded),
            )
            .onPressed,
        isNull,
      );
      final firstRow = find.byKey(
        const ValueKey('material-bom-node-material-path-1'),
      );
      final adopt = find.descendant(
        of: firstRow,
        matching: find.byKey(
          const ValueKey('material-adopt-route-material-path-1'),
        ),
      );
      expect(tester.widget<OutlinedButton>(adopt).onPressed, isNull);
      await tester.tap(
        find.byKey(
          const ValueKey('material-node-details-toggle-material-path-1'),
        ),
      );
      await tester.pumpAndSettle();
      final dropdown = find.descendant(
        of: firstRow,
        matching: find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
      );
      expect(
        tester
            .widget<DropdownButtonFormField<MaterialSupplyRoute>>(dropdown)
            .onChanged,
        isNull,
      );
      expect(find.byKey(const Key('material-analysis-generate')), findsNothing);
      expect(
        harness.requests.where(
          (request) =>
              request.path.endsWith('/routes') ||
              request.path.endsWith('/notify') ||
              request.path.endsWith('/generate-plan'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets(
    'inactive deep node still shows its own demand allocation and warehouse stock',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(520, 900),
        permissions: const {Perm.productionMaterialAnalysisManage},
        allowedActions: const ['VIEW'],
      );

      final dependencyRow = find.byKey(
        const ValueKey('material-bom-node-dependency-node-1'),
      );
      await tester.scrollUntilVisible(
        dependencyRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: dependencyRow, matching: find.text('需 20')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dependencyRow, matching: find.text('配 4')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dependencyRow, matching: find.text('现货 7')),
        findsOneWidget,
      );
      expect(find.textContaining('路径：测试产品'), findsNothing);
      expect(find.textContaining('随上级件'), findsNothing);
      expect(
        find.descendant(
          of: dependencyRow,
          matching: find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'allocation priority cancel is local and confirm writes the complete CAS order',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisReallocate,
        },
        allowedActions: const ['REALLOCATE'],
      );

      await tester.tap(
        find.byKey(const Key('material-analysis-priority-edit')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('material-analysis-priority-editor')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('material-priority-down-0')),
      );
      await tester.tap(
        find.byKey(const Key('material-analysis-priority-cancel')),
      );
      await tester.pumpAndSettle();
      expect(
        harness.requests.where(
          (request) => request.path.endsWith('/allocation-priorities'),
        ),
        isEmpty,
      );

      await tester.tap(
        find.byKey(const Key('material-analysis-priority-edit')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('material-priority-down-0')),
      );
      await tester.tap(
        find.byKey(const Key('material-analysis-priority-save')),
      );
      await tester.pumpAndSettle();

      final request = harness.requests.singleWhere(
        (request) => request.path.endsWith('/allocation-priorities'),
      );
      expect(request.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'items': [
          {'analysisLineId': 'product-line-2', 'priority': 1},
          {'analysisLineId': 'product-line-1', 'priority': 2},
        ],
      });
    },
  );

  testWidgets('compact allocation priority editor stays reachable and usable', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(375, 900),
      permissions: const {
        Perm.productionMaterialAnalysisManage,
        Perm.productionMaterialAnalysisReallocate,
      },
      allowedActions: const ['REALLOCATE'],
    );

    await tester.tap(find.byKey(const Key('material-analysis-priority-edit')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('material-analysis-priority-editor')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('material-priority-down-0')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact layout defaults to the full independent BOM tree', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(375, 900),
      permissions: const {Perm.productionMaterialAnalysisManage},
      allowedActions: const ['VIEW'],
    );

    final deepRow = find.byKey(
      const ValueKey('material-bom-node-material-path-2'),
    );
    await tester.scrollUntilVisible(
      deepRow,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.byKey(const ValueKey('material-bom-node-material-path-1')),
      findsOneWidget,
    );
    expect(deepRow, findsOneWidget);
    expect(find.textContaining('涉及 2 条路径'), findsNothing);
    expect(
      find.byType(DropdownButtonFormField<MaterialSupplyRoute>),
      findsNothing,
    );
    expect(find.textContaining('需 '), findsWidgets);
    expect(find.textContaining('配 '), findsWidgets);
    expect(find.textContaining('缺 '), findsWidgets);
    expect(find.text('计划日期 未设置'), findsNothing);
    expect(find.byKey(const Key('material-analysis-generate')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'default BOM view hides covered nodes and all view restores the full count',
    (tester) async {
      final json = _makeTreeAnalysisJson()..['allowedActions'] = const ['VIEW'];
      final materials = (json['flatMaterials'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final coveredChild = materials.firstWhere(
        (material) => material['materialLineId'] == 'buy-child',
      );
      coveredChild
        ..['allocatedAvailableQty'] = 10
        ..['availableQty'] = 10
        ..['shortageQty'] = 0;

      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {Perm.productionMaterialAnalysisManage},
        allowedActions: const ['VIEW'],
        analysisJson: json,
      );

      final viewAll = find.byKey(const ValueKey('material-bom-view-all'));
      await tester.scrollUntilVisible(
        viewAll,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('只看缺料 2'), findsOneWidget);
      expect(find.text('待确认路线 0'), findsOneWidget);
      expect(find.text('全部 BOM 3'), findsOneWidget);
      expect(find.text('筛选命中 2 条；保留上级后共 2 条 / 全部 3 条'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('material-bom-node-node-buy-child')),
        findsNothing,
      );

      await tester.tap(viewAll);
      await tester.pumpAndSettle();
      expect(find.text('筛选命中 3 条；保留上级后共 3 条 / 全部 3 条'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('material-bom-node-node-buy-child')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'BOM child search keeps its product header and nonmatching ancestor context',
    (tester) async {
      final json = _makeTreeAnalysisJson()..['allowedActions'] = const ['VIEW'];
      final materials = (json['flatMaterials'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final parent = materials.firstWhere(
        (material) => material['materialLineId'] == 'make-path-1',
      );
      parent
        ..['allocatedAvailableQty'] = 10
        ..['availableQty'] = 10
        ..['shortageQty'] = 0;

      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {Perm.productionMaterialAnalysisManage},
        allowedActions: const ['VIEW'],
        analysisJson: json,
      );

      final search = find.byKey(const Key('material-bom-search'));
      await tester.scrollUntilVisible(
        search,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(search, '外箱依赖');
      await tester.pumpAndSettle();

      expect(find.text('筛选命中 1 条；保留上级后共 2 条 / 全部 3 条'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('material-bom-product-product-line-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-bom-node-node-make-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-bom-node-node-buy-child')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-bom-node-node-make-2')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'large product set renders 60 cards first and continues on demand',
    (tester) async {
      final json = _analysisJson(const ['VIEW']);
      json
        ..['products'] = [
          for (var index = 1; index <= 61; index++)
            {
              'analysisLineId': 'bulk-product-$index',
              'sourceType': 'STOCK',
              'sourceRef': 'STOCK-$index',
              'goodsCode': 'BULK-$index',
              'goodsName': '批量产品 $index',
              'requestedQty': 1,
              'remainingQty': 1,
              'readyNowQty': 1,
              'readyByDateQty': 1,
              'readinessRatio': 1,
              'productionBomPolicy': 'DIRECT_MAKE',
              'missingBom': false,
              'bomOverrideRequired': false,
              'hasActiveBom': false,
              'allocationPriority': index,
            },
        ]
        ..['flatMaterials'] = <Map<String, dynamic>>[];

      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {Perm.productionMaterialAnalysisManage},
        allowedActions: const ['VIEW'],
        analysisJson: json,
      );

      expect(
        find.byKey(const ValueKey('material-analysis-product-bulk-product-60')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-analysis-product-bulk-product-61')),
        findsNothing,
      );
      final showMore = find.byKey(
        const Key('material-analysis-show-more-products'),
      );
      expect(find.text('继续显示下一批（还有 1 个）'), findsOneWidget);
      final button = tester.widget<UtenButton>(showMore);
      expect(button.onPressed, isNotNull);
      button.onPressed!();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('material-analysis-product-bulk-product-61')),
        findsOneWidget,
      );
      expect(showMore, findsNothing);
    },
  );

  testWidgets(
    'product and BOM branch are expanded by default and independently foldable',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {Perm.productionMaterialAnalysisManage},
        allowedActions: const ['VIEW'],
        analysisJson: _makeTreeAnalysisJson()
          ..['allowedActions'] = const ['VIEW'],
      );

      final productToggle = find.byKey(
        const ValueKey('material-bom-product-toggle-product-line-1'),
      );
      final makeNode = find.byKey(
        const ValueKey('material-bom-node-node-make-1'),
      );
      final buyChild = find.byKey(
        const ValueKey('material-bom-node-node-buy-child'),
      );
      await tester.scrollUntilVisible(
        productToggle,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(makeNode, findsOneWidget);
      expect(buyChild, findsOneWidget);

      await tester.tap(productToggle);
      await tester.pumpAndSettle();
      expect(makeNode, findsNothing);
      expect(buyChild, findsNothing);

      await tester.tap(productToggle);
      await tester.pumpAndSettle();
      expect(makeNode, findsOneWidget);
      expect(buyChild, findsOneWidget);

      final branchToggle = find.byKey(
        const ValueKey('material-bom-branch-toggle-node-make-1'),
      );
      await tester.tap(branchToggle);
      await tester.pumpAndSettle();
      expect(makeNode, findsOneWidget);
      expect(buyChild, findsNothing);

      await tester.tap(branchToggle);
      await tester.pumpAndSettle();
      expect(buyChild, findsOneWidget);
    },
  );

  testWidgets(
    'route rows support tri-state selection, deep-green state and subset notify',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _buySelectionAnalysisJson(),
        responseOverride: (request) => request.path.endsWith('/notify')
            ? _buySelectionNotifiedAnalysisJson()
            : null,
      );

      final header = find.byKey(
        const ValueKey('material-route-select-all-BUY'),
      );
      await tester.scrollUntilVisible(
        header,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(header), alignment: 0.5);
      await tester.pump();
      expect(tester.widget<Checkbox>(header).value, isFalse);

      await tester.tap(header);
      await tester.pump();
      expect(tester.widget<Checkbox>(header).value, isTrue);
      expect(find.text('提交采购需求（2）'), findsOneWidget);

      final first = find.byKey(
        const ValueKey('material-bom-select-buy-line-1'),
      );
      await tester.tap(first);
      await tester.pump();
      expect(tester.widget<Checkbox>(header).value, isNull);
      expect(find.text('提交采购需求（1）'), findsOneWidget);

      final selectedRow = tester.widget<Container>(
        find.byKey(const ValueKey('material-bom-node-buy-node-2')),
      );
      expect(
        ((selectedRow.decoration as BoxDecoration).color),
        UtenColors.deepGreen,
      );

      final subcontract = find.byKey(
        const ValueKey('material-bom-select-subcontract-line-1'),
      );
      await tester.ensureVisible(subcontract);
      await tester.pump();
      await tester.tap(subcontract);
      await tester.pump();
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: subcontract, matching: find.byType(Checkbox)),
            )
            .value,
        isTrue,
      );

      final buyNotify = find.text('提交采购需求（1）');
      await tester.ensureVisible(buyNotify);
      await tester.pump();
      await tester.tap(buyNotify);
      await tester.pumpAndSettle();
      final request = harness.requests.singleWhere(
        (request) => request.path.endsWith('/notify'),
      );
      expect(request.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'target': 'BUY',
        'actionGroupKeys': ['buy-action-2'],
      });
      expect(tester.widget<Checkbox>(header).value, isFalse);
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(of: subcontract, matching: find.byType(Checkbox)),
            )
            .value,
        isTrue,
      );
    },
  );

  testWidgets(
    'MAKE tree preserves DFS order without merging repeated material paths',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _makeTreeAnalysisJson(),
      );

      final tree = find.byKey(const Key('material-bom-tree'));
      await tester.scrollUntilVisible(
        tree,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(const ValueKey('material-bom-product-product-line-1')),
        findsOneWidget,
      );
      expect(find.text('装配'), findsNothing);
      expect(find.text('发货参考'), findsNothing);
      expect(find.textContaining('涉及 2 条路径'), findsNothing);
      expect(
        find.byKey(const ValueKey('material-bom-node-node-make-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('material-bom-node-node-make-2')),
        findsOneWidget,
      );
      // DFS：父件 node-make-1 行在子件 node-buy-child 行之上。
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('material-bom-node-node-make-1')),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey('material-bom-node-node-buy-child')),
              )
              .dy,
        ),
      );
      // depth>1 缺料件（外箱依赖，层级 2）也可直接操作：带勾选框。
      final buyChildRow = find.byKey(
        const ValueKey('material-bom-node-node-buy-child'),
      );
      expect(
        find.descendant(of: buyChildRow, matching: find.byType(Checkbox)),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('material-node-details-toggle-make-path-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('装配'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('material-node-details-toggle-buy-child')),
      );
      await tester.pumpAndSettle();
      expect(find.text('发货参考'), findsOneWidget);
    },
  );

  testWidgets(
    'unified tree depth>1 shortage node is actionable (checkbox and route)',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisRoute,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _makeTreeAnalysisJson(),
      );

      final depNode = find.byKey(
        const ValueKey('material-bom-node-node-buy-child'),
      );
      await tester.scrollUntilVisible(
        depNode,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      // depth>1 的缺料件同样可操作：可勾选、可确认路线（按类型采购/委外/自制）。
      final selectControl = find.byKey(
        const ValueKey('material-bom-select-buy-child'),
      );
      expect(tester.getSize(selectControl).height, greaterThanOrEqualTo(48));
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(
                of: selectControl,
                matching: find.byType(Checkbox),
              ),
            )
            .onChanged,
        isNotNull,
      );
      await tester.tap(selectControl);
      await tester.pump();
      expect(
        tester
            .widget<Checkbox>(
              find.descendant(
                of: selectControl,
                matching: find.byType(Checkbox),
              ),
            )
            .value,
        isTrue,
      );
      expect(find.text('提交采购需求（1）'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('material-node-details-toggle-buy-child')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<MaterialSupplyRoute>>(
              find.descendant(
                of: depNode,
                matching: find.byType(
                  DropdownButtonFormField<MaterialSupplyRoute>,
                ),
              ),
            )
            .onChanged,
        isNotNull,
      );
    },
  );

  testWidgets(
    'MAKE lowerLevelPending explains the gate and cannot create a task',
    (tester) async {
      final json = _makeTreeAnalysisJson();
      final material =
          (json['flatMaterials'] as List<dynamic>).first
              as Map<String, dynamic>;
      material['lowerLevelPending'] = true;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: json,
      );

      final makeRow = find.byKey(
        const ValueKey('material-bom-node-node-make-1'),
      );
      await tester.scrollUntilVisible(
        makeRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.descendant(of: makeRow, matching: find.textContaining('待齐套')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: makeRow,
          matching: find.byKey(
            const ValueKey('material-node-action-make-path-1'),
          ),
        ),
        findsNothing,
      );
      final gateControl = find.byKey(
        const ValueKey('material-bom-gate-make-path-1'),
      );
      expect(tester.getSize(gateControl).height, greaterThanOrEqualTo(48));
      expect(
        find.descendant(of: gateControl, matching: find.text('下层未齐')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: gateControl, matching: find.byType(Checkbox)),
        findsNothing,
      );
      expect(
        find.descendant(of: makeRow, matching: find.byType(Checkbox)),
        findsNothing,
      );
      expect(
        harness.requests.where((request) => request.path.endsWith('/notify')),
        isEmpty,
      );
    },
  );

  testWidgets(
    'MAKE arrange production creates child task then opens its plan wizard',
    (tester) async {
      final initial = _makeTreeAnalysisJson()
        ..['allowedActions'] = const ['NOTIFY_SUPPLY', 'GENERATE_PLAN'];
      final notified = _makeReadyChildAnalysisJson();
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisNotify,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: initial,
        responseOverride: (request) =>
            request.path.endsWith('/notify') ? notified : null,
      );

      final makeRow = find.byKey(
        const ValueKey('material-bom-node-node-make-1'),
      );
      await tester.scrollUntilVisible(
        makeRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final arrange = find.descendant(
        of: makeRow,
        matching: find.byKey(
          const ValueKey('material-node-action-make-path-1'),
        ),
      );
      expect(
        find.descendant(of: arrange, matching: find.text('安排生产')),
        findsOneWidget,
      );
      await tester.tap(arrange);
      await tester.pumpAndSettle();

      final notify = harness.requests.singleWhere(
        (request) => request.path.endsWith('/notify'),
      );
      expect(notify.data, {
        'version': 3,
        'fingerprint': 'a' * 64,
        'idempotencyKey': isA<String>(),
        'target': 'MAKE',
        'actionGroupKeys': ['make-action-1'],
      });
      expect(find.text('填写生产计划单'), findsWidgets);
      expect(
        find.byKey(
          const ValueKey('production-plan-wizard-qty-make-child-ready-1'),
        ),
        findsOneWidget,
      );
      expect(
        find.byType(ProductionMaterialAnalysisPage, skipOffstage: false),
        findsOneWidget,
      );

      // Cancelling the form pops only the wizard. The created child task stays
      // on the refreshed analysis for another planner to continue later.
      await tester.tap(find.byTooltip('返回物料分析'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('material-analysis-results')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('material-analysis-product-make-child-ready-1'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('待安排生产'), findsWidgets);
      expect(
        harness.requests.where(
          (request) =>
              request.path.endsWith('/plan-preview') ||
              request.path.endsWith('/generate-plan'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets('MAKE row shows server execution status and latest plan link', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      size: const Size(1400, 1000),
      permissions: const {
        Perm.productionMaterialAnalysisManage,
        Perm.productionMaterialAnalysisNotify,
      },
      analysisJson: _makeStatusAnalysisJson(
        childSubmitted: 5,
        planExecutionStatus: 'IN_PROGRESS',
        latestPlanId: 'plan-make-1',
        latestPlanNo: 'PP-MAKE-001',
      ),
    );
    final makeRow = find.byKey(
      const ValueKey('material-bom-node-node-make-short-1'),
    );
    await tester.scrollUntilVisible(
      makeRow,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.descendant(of: makeRow, matching: find.text('生产中')),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: makeRow,
        matching: find.byKey(const ValueKey('material-view-plan-make-short-1')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: makeRow, matching: find.text('PP-MAKE-001')),
      findsOneWidget,
    );
  });

  testWidgets(
    'selected product uses wizard fields, submits only for approval and resets next batch',
    (tester) async {
      final firstRound = _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']);
      final firstRoundProducts = firstRound['products']! as List<dynamic>;
      (firstRoundProducts.first as Map<String, dynamic>)
        ..['readyStartQty'] = 6
        ..['readyFinishQty'] = 4
        ..['readyShipQty'] = 2;
      final secondRound = _analysisJson(const [
        'PLAN_PREVIEW',
        'GENERATE_PLAN',
      ]);
      final products = secondRound['products']! as List<dynamic>;
      (products.first as Map<String, dynamic>)
        ..['readyNowQty'] = 1
        ..['readyFinishQty'] = 1;
      final harness = await _pumpPage(
        tester,
        size: const Size(1400, 1000),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisGenerate,
        },
        analysisJson: firstRound,
        billDate: '2026-08-09',
        deliveryDate: '2026-08-12',
        departmentId: 'workshop-1',
        workshopName: '装配一车间',
        workerId: 'worker-1',
        responseOverride: (request) {
          if (request.path.endsWith('/plan-preview')) {
            return {
              'analysisId': 'analysis-1',
              'version': 3,
              'fingerprint': 'a' * 64,
              'previewFingerprint': 'c' * 64,
              'warehouseId': 'warehouse-1',
              'allReady': true,
              'allowedActions': ['GENERATE_PLAN'],
              'items': [
                {
                  'analysisLineId': 'product-line-1',
                  'requestedQty': 10,
                  'readyNowQty': 4,
                  'selectedQty': 3,
                  'canGenerate': true,
                },
              ],
            };
          }
          if (request.path.endsWith('/generate-plan')) {
            return {
              'analysis': secondRound,
              'plans': [
                {'planId': 'plan-1', 'planNo': 'PP-20260809-001'},
              ],
            };
          }
          return null;
        },
      );

      final firstProductCard = find.byKey(
        const ValueKey('material-analysis-product-product-line-1'),
      );
      // The headline leads with the authoritative max-producible qty
      // (readyNowQty = 4); the misleading "可开工" wording is gone.
      expect(
        find.descendant(of: firstProductCard, matching: find.text('最多可生产 4 个')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: firstProductCard, matching: find.text('齐套 40%')),
        findsOneWidget,
      );
      // Secondary stage quantities and the batch input stay collapsed until
      // the planner selects this product.
      expect(
        find.descendant(
          of: firstProductCard,
          matching: find.textContaining('开工段就绪 6'),
        ),
        findsNothing,
      );
      expect(find.byKey(const Key('batch-qty-product-line-1')), findsNothing);
      await tester.tap(
        find.byKey(
          const ValueKey('material-analysis-product-select-product-line-1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: firstProductCard,
          matching: find.textContaining('开工段就绪 6'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: firstProductCard,
          matching: find.textContaining('含包装可发 2'),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('batch-qty-product-line-1')),
            )
            .controller
            ?.text,
        '4',
      );
      expect(
        find.descendant(of: firstProductCard, matching: find.text('最多 4 个')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('batch-qty-product-line-1')),
        '3',
      );
      expect(find.text('生成总装计划（1）'), findsOneWidget);
      await tester.tap(find.text('生成总装计划（1）'));
      await tester.pumpAndSettle();
      expect(find.text('生产计划单'), findsWidgets);

      await tester.tap(find.text('汇总确认'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('production-plan-wizard-submit')));
      await tester.pumpAndSettle();

      expect(find.text('生产计划已生成'), findsOneWidget);
      expect(find.textContaining('PP-20260809-001'), findsOneWidget);
      expect(find.text('留在物料分析'), findsOneWidget);
      expect(find.text('查看计划'), findsOneWidget);
      await tester.tap(find.text('留在物料分析'));
      await tester.pumpAndSettle();

      final generate = harness.requests.singleWhere(
        (request) => request.path.endsWith('/generate-plan'),
      );
      final body = generate.data! as Map<String, dynamic>;
      expect(body['approveNow'], isFalse);
      expect(body['departmentId'], 'workshop-1');
      expect(body['workerId'], 'worker-1');
      expect(body['items'], [
        {
          'analysisLineId': 'product-line-1',
          'qty': 3.0,
          'billDate': '2026-08-09',
          'deliveryDate': '2026-08-12',
          'departmentId': 'workshop-1',
          'workshopName': '装配一车间',
          'workerId': 'worker-1',
        },
      ]);
      // A server refresh clears selection and collapses plan-only fields.
      expect(find.byKey(const Key('batch-qty-product-line-1')), findsNothing);
      expect(find.byKey(const Key('material-analysis-generate')), findsNothing);
      expect(
        find.byKey(const Key('material-analysis-results')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'product cards show kitting progress bar and shortage kind summary',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {Perm.productionMaterialAnalysisManage},
      );

      final firstCard = find.byKey(
        const ValueKey('material-analysis-product-product-line-1'),
      );
      expect(
        find.descendant(
          of: firstCard,
          matching: find.byKey(
            const ValueKey('material-analysis-product-progress-product-line-1'),
          ),
        ),
        findsOneWidget,
      );
      // 测试产品下有 3 条缺料路径（共享紧固件×2 + 下层依赖件），路线均未确认。
      expect(
        find.descendant(
          of: firstCard,
          matching: find.text('还缺 3 种料 · 其中 3 条路线待确认'),
        ),
        findsOneWidget,
      );
      // 第二产品没有缺料路径，不显示缺口摘要。
      final secondCard = find.byKey(
        const ValueKey('material-analysis-product-product-line-2'),
      );
      expect(
        find.descendant(of: secondCard, matching: find.textContaining('还缺')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'BOM node rows show coverage progress bar with honest quantities',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {Perm.productionMaterialAnalysisManage},
      );
      final firstRow = find.byKey(
        const ValueKey('material-bom-node-material-path-1'),
      );
      await tester.scrollUntilVisible(
        firstRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      // 需 16、缺 11 → 覆盖 5 → 31%。口径与状态文字同源（合格覆盖 ÷ 需求），
      // 不混用报工/成品入库。
      expect(
        find.descendant(
          of: firstRow,
          matching: find.byKey(
            const ValueKey('material-node-progress-material-path-1'),
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: firstRow, matching: find.text('备料 31% · 已备 5/16')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'material aggregate view merges shared material across products and keeps per-path selection',
    (tester) async {
      await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisNotify,
        },
        analysisJson: _aggregateAnalysisJson(),
      );

      final layoutToggle = find.byKey(
        const ValueKey('material-bom-layout-material'),
      );
      await tester.scrollUntilVisible(
        layoutToggle,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(layoutToggle);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('material-aggregate-list')), findsOneWidget);
      // 同一物料跨两个产品、两条路径聚成一行：需求与缺口加总，
      // 现货取共享池快照（各路径同源，不重复计数）。
      final sharedRow = find.byKey(
        const ValueKey('material-aggregate-goods-shared-motor||个'),
      );
      expect(sharedRow, findsOneWidget);
      expect(
        find.descendant(of: sharedRow, matching: find.text('共需 15')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sharedRow, matching: find.text('现货 4')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sharedRow, matching: find.text('共缺 11')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sharedRow, matching: find.text('2 个产品要用')),
        findsOneWidget,
      );
      // 展开前不渲染逐路径明细。
      expect(
        find.byKey(const ValueKey('material-aggregate-path-agg-path-1')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(
          const ValueKey('material-aggregate-toggle-goods-shared-motor||个'),
        ),
      );
      await tester.pumpAndSettle();
      final firstPath = find.byKey(
        const ValueKey('material-aggregate-path-agg-path-1'),
      );
      final secondPath = find.byKey(
        const ValueKey('material-aggregate-path-agg-path-2'),
      );
      expect(firstPath, findsOneWidget);
      expect(secondPath, findsOneWidget);
      expect(
        find.descendant(of: firstPath, matching: find.text('测试产品')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: secondPath, matching: find.text('第二测试产品')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: firstPath, matching: find.text('缺 6')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: secondPath, matching: find.text('缺 5')),
        findsOneWidget,
      );

      // 勾选两条路径 → 底部按路线汇总为一次采购提交；任务身份仍逐路径独立。
      // 展开后的路径行可能位于视口下方，先滚动到可见再点选。
      final firstSelect = find.byKey(
        const ValueKey('material-bom-select-agg-path-1'),
      );
      await tester.scrollUntilVisible(
        firstSelect,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(firstSelect);
      await tester.pumpAndSettle();
      final secondSelect = find.byKey(
        const ValueKey('material-bom-select-agg-path-2'),
      );
      await tester.scrollUntilVisible(
        secondSelect,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(secondSelect);
      await tester.pumpAndSettle();
      expect(find.text('提交采购需求（2）'), findsOneWidget);
    },
  );

  testWidgets(
    'borrow moves stock coverage between products with dual visibility',
    (tester) async {
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisReallocate,
        },
        analysisJson: _aggregateAnalysisJson(),
        responseOverride: (request) {
          if (request.path.endsWith('/borrows')) {
            return _borrowedAnalysisJson();
          }
          return null;
        },
      );

      // 打开借出节点（测试产品 · 共享电机）的详情，进入调拨对话框。
      final firstRow = find.byKey(
        const ValueKey('material-bom-node-agg-node-1'),
      );
      await tester.scrollUntilVisible(
        firstRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      final details = find.byKey(
        const ValueKey('material-node-details-toggle-agg-path-1'),
      );
      expect(details, findsOneWidget);
      await tester.tap(details);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('material-borrow-start-agg-path-1')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('material-borrow-dialog')), findsOneWidget);
      // 只列出其它产品中缺同种料的路径（第二测试产品 · 共享电机）。
      await tester.tap(
        find.byKey(const ValueKey('material-borrow-target-agg-path-2')),
      );
      await tester.pumpAndSettle();
      // 默认值先行：数量预填 min(借出已分配 4, 对方缺口 5) = 4。
      expect(
        find.descendant(
          of: find.byKey(const Key('material-borrow-qty')),
          matching: find.text('4'),
        ),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('material-borrow-reason')),
        '客户加急，先保这单',
      );
      await tester.pumpAndSettle();
      // 确认前必须看到双方影响的大白话提示。
      expect(find.textContaining('会重新缺 4 件该料'), findsOneWidget);
      await tester.tap(find.byKey(const Key('material-borrow-confirm')));
      await tester.pumpAndSettle();

      final borrowRequest = harness.requests.singleWhere(
        (request) => request.path.endsWith('/borrows'),
      );
      final body = borrowRequest.data! as Map<String, dynamic>;
      expect(body['fromMaterialLineId'], 'agg-path-1');
      expect(body['toMaterialLineId'], 'agg-path-2');
      expect(body['qty'], 4.0);
      expect(body['reason'], '客户加急，先保这单');

      // 服务端重算后：借出方行显示"已被调走 · 调给 第二测试产品"，
      // 借入方行（在第二产品的 BOM 区，需滚动到可见）显示"已调入 · 来自 测试产品"。
      expect(find.text('已被调走 4 件 · 调给 第二测试产品'), findsOneWidget);
      final secondRow = find.byKey(
        const ValueKey('material-bom-node-agg-node-2'),
      );
      await tester.scrollUntilVisible(
        secondRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('已调入 4 件 · 来自 测试产品'), findsOneWidget);
    },
  );

  testWidgets('active borrow can be revoked with an audited reason', (
    tester,
  ) async {
    final harness = await _pumpPage(
      tester,
      size: const Size(1200, 900),
      permissions: const {
        Perm.productionMaterialAnalysisManage,
        Perm.productionMaterialAnalysisReallocate,
      },
      analysisJson: _borrowedAnalysisJson(),
      responseOverride: (request) {
        if (request.path.endsWith('/revoke')) {
          return _aggregateAnalysisJson();
        }
        return null;
      },
    );

    // 借出方详情里能看到逐笔明细并撤销。
    final fromRow = find.byKey(const ValueKey('material-bom-node-agg-node-1'));
    await tester.scrollUntilVisible(
      fromRow,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final details = find.byKey(
      const ValueKey('material-node-details-toggle-agg-path-1'),
    );
    expect(details, findsOneWidget);
    await tester.tap(details);
    await tester.pumpAndSettle();
    expect(find.textContaining('借出 4 件 · 调给 第二测试产品'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('material-borrow-revoke-borrow-1')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('borrow-revoke-reason')),
      '对方那单延期了，先撤回来',
    );
    await tester.tap(find.text('确认撤销'));
    await tester.pumpAndSettle();

    final revokeRequest = harness.requests.singleWhere(
      (request) => request.path.endsWith('/borrows/borrow-1/revoke'),
    );
    final body = revokeRequest.data! as Map<String, dynamic>;
    expect(body['reason'], '对方那单延期了，先撤回来');
    // 撤销后刷新视图：双向徽标消失。
    expect(find.textContaining('已被调走'), findsNothing);
    expect(find.textContaining('已调入'), findsNothing);
  });

  testWidgets(
    'server allowedActions gate hides borrow and revoke despite local permission',
    (tester) async {
      final analysisJson = _borrowedAnalysisJson()
        ..['allowedActions'] = const ['VIEW'];
      final harness = await _pumpPage(
        tester,
        size: const Size(1200, 900),
        // manage 只是让预览发生；借用入口的服务端门禁才是本用例验证点。
        permissions: const {
          Perm.productionMaterialAnalysisManage,
          Perm.productionMaterialAnalysisReallocate,
        },
        analysisJson: analysisJson,
      );

      final fromRow = find.byKey(
        const ValueKey('material-bom-node-agg-node-1'),
      );
      await tester.scrollUntilVisible(
        fromRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(
        find.byKey(const ValueKey('material-node-details-toggle-agg-path-1')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('material-borrow-revoke-borrow-1')),
        findsNothing,
      );

      final toRow = find.byKey(const ValueKey('material-bom-node-agg-node-2'));
      await tester.scrollUntilVisible(
        toRow,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(
        find.byKey(const ValueKey('material-node-details-toggle-agg-path-2')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('material-borrow-start-agg-path-2')),
        findsNothing,
      );
      expect(
        harness.requests.where(
          (request) =>
              request.path.endsWith('/borrows') ||
              request.path.contains('/borrows/'),
        ),
        isEmpty,
      );
    },
  );
}

Future<void> _chooseRoute(WidgetTester tester, String label) async {
  var routeFinder = find.byType(DropdownButtonFormField<MaterialSupplyRoute>);
  if (routeFinder.evaluate().isEmpty) {
    final details = find.byKey(
      const ValueKey('material-node-details-toggle-material-path-1'),
    );
    await tester.scrollUntilVisible(
      details,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(details);
    await tester.pumpAndSettle();
    routeFinder = find.byType(DropdownButtonFormField<MaterialSupplyRoute>);
  }
  await tester.ensureVisible(routeFinder);
  await tester.pumpAndSettle();
  await tester.tap(routeFinder);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<_Harness> _pumpPage(
  WidgetTester tester, {
  required Size size,
  required Set<String> permissions,
  List<String> allowedActions = const ['PLAN_PREVIEW', 'GENERATE_PLAN'],
  bool seeded = true,
  String? analysisId,
  List<MaterialAnalysisSourceInput>? sources,
  Map<String, dynamic>? analysisJson,
  DioException? Function(RequestOptions request)? errorOverride,
  Map<String, dynamic>? Function(RequestOptions request)? responseOverride,
  String? billDate,
  String? deliveryDate,
  String? departmentId,
  String? workshopName,
  String? workerId,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final requests = <RequestOptions>[];
  final api = _api(
    requests,
    allowedActions,
    analysisJson: analysisJson,
    errorOverride: errorOverride,
    responseOverride: responseOverride,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        productionPlanRepositoryProvider.overrideWithValue(
          ProductionPlanRepository(api),
        ),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        departmentPickerTreeProvider.overrideWith(
          (ref) async => const <DepartmentNode>[],
        ),
        productionWorkshopTreeProvider.overrideWith(
          (ref) async => _productionWorkshops(),
        ),
        currentPermissionsProvider.overrideWithValue(permissions),
      ],
      child: MaterialApp(
        home: ProductionMaterialAnalysisPage(
          seed: ProductionMaterialAnalysisSeed(
            analysisId: analysisId,
            warehouseId: 'warehouse-1',
            billDate: billDate,
            deliveryDate: deliveryDate,
            departmentId: departmentId,
            workshopName: workshopName,
            workerId: workerId,
            sources:
                sources ??
                (seeded
                    ? const [
                        MaterialAnalysisSourceInput(
                          salesOrderItemId: 'sales-line-1',
                          requestedQty: 10,
                        ),
                      ]
                    : const []),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  return _Harness(requests);
}

List<DepartmentNode> _productionWorkshops() => [
  DepartmentNode(
    id: 'workshop-1',
    code: 'WS_ASSEMBLY_1',
    name: '装配一车间',
    level: '一级部门',
    children: const [],
  ),
];

ApiClient _api(
  List<RequestOptions> requests,
  List<String> allowedActions, {
  Map<String, dynamic>? analysisJson,
  DioException? Function(RequestOptions request)? errorOverride,
  Map<String, dynamic>? Function(RequestOptions request)? responseOverride,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        final failure = errorOverride?.call(request);
        if (failure != null) {
          handler.reject(failure);
          return;
        }
        final custom = responseOverride?.call(request);
        final data =
            custom ??
            switch (request.path) {
              '/master/warehouses/dict' => [
                {'id': 'warehouse-1', 'name': '主仓'},
              ],
              '/production/material-analyses/preview' =>
                analysisJson ?? _analysisJson(allowedActions),
              '/production/material-analyses/analysis-1' =>
                analysisJson ?? _analysisJson(allowedActions),
              '/production/material-analyses/sales-candidates' => {
                'items': <Map<String, dynamic>>[],
                'page': 1,
                'size': 20,
                'total': 0,
                'totalPages': 1,
              },
              '/production/material-analyses/analysis-1/routes' =>
                _analysisJson(allowedActions, routeConfirmed: true),
              '/production/material-analyses/analysis-1/notify' =>
                analysisJson ?? _analysisJson(allowedActions),
              '/production/material-analyses/analysis-1/allocation-priorities' =>
                _analysisJson(allowedActions),
              _ => <Map<String, dynamic>>[],
            };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

Map<String, dynamic> _salesCandidatesJson() => {
  'items': [
    {
      'orderId': 'sales-order-1',
      'billNo': 'SO-20260811-001',
      'billDate': '2026-08-11',
      'clientName': '测试客户',
      'lines': [
        {
          'salesOrderItemId': 'sales-line-a',
          'lineNo': 1,
          'goodsId': 'goods-a',
          'goodsCode': 'A-001',
          'goodsName': '候选产品 A',
          'unitId': 'unit-1',
          'unitName': '个',
          'orderedQty': 10,
          'alreadyPlannedQty': 2,
          'remainingQty': 8,
          'deliveryDate': '2026-08-20',
        },
        {
          'salesOrderItemId': 'sales-line-b',
          'lineNo': 2,
          'goodsId': 'goods-b',
          'goodsCode': 'B-001',
          'goodsName': '候选产品 B',
          'unitId': 'unit-1',
          'unitName': '个',
          'orderedQty': 6,
          'alreadyPlannedQty': 1,
          'remainingQty': 5,
          'deliveryDate': '2026-08-22',
        },
      ],
    },
  ],
  'page': 1,
  'size': 100,
  'total': 1,
  'totalPages': 1,
};

Map<String, dynamic> _pagedSalesCandidatesJson(int page) {
  final firstPage = page <= 1;
  final suffix = firstPage ? 'a' : 'b';
  final label = firstPage ? 'A' : 'B';
  return {
    'items': [
      {
        'orderId': 'mobile-sales-order-$suffix',
        'billNo': 'SO-MOBILE-$label',
        'billDate': '2026-08-11',
        'clientName': '手机测试客户',
        'lines': [
          {
            'salesOrderItemId': 'mobile-sales-line-$suffix',
            'lineNo': 1,
            'goodsId': 'mobile-goods-$suffix',
            'goodsCode': 'MOBILE-$label',
            'goodsName': '手机候选产品 $label',
            'unitId': 'unit-1',
            'unitName': '个',
            'orderedQty': 10,
            'alreadyPlannedQty': firstPage ? 2 : 3,
            'remainingQty': firstPage ? 8 : 7,
            'deliveryDate': firstPage ? '2026-08-20' : '2026-08-22',
          },
        ],
      },
    ],
    'page': firstPage ? 1 : 2,
    'size': 100,
    'total': 2,
    'totalPages': 2,
  };
}

Map<String, dynamic> _analysisJson(
  List<String> allowedActions, {
  bool routeConfirmed = false,
}) => {
  'analysisId': 'analysis-1',
  'status': 'ANALYZED',
  'version': 3,
  'fingerprint': 'a' * 64,
  'warehouseId': 'warehouse-1',
  'analyzedAt': '2026-08-08T10:00:00Z',
  'allowedActions': allowedActions,
  'products': [
    {
      'analysisLineId': 'product-line-1',
      'salesOrderItemId': 'sales-line-1',
      'orderNo': 'SO-1',
      'goodsCode': 'P-1',
      'goodsName': '测试产品',
      'requestedQty': 10,
      'remainingQty': 10,
      'readyNowQty': 4,
      'readyByDateQty': 8,
      'readinessRatio': 0.4,
      'productionBomPolicy': 'DIRECT_MAKE',
      'missingBom': false,
      'bomOverrideRequired': false,
      'hasActiveBom': false,
      'allocationPriority': 1,
    },
    {
      'analysisLineId': 'product-line-2',
      'sourceType': 'STOCK',
      'goodsCode': 'P-2',
      'goodsName': '第二测试产品',
      'requestedQty': 6,
      'remainingQty': 6,
      'readyNowQty': 2,
      'readyByDateQty': 4,
      'readinessRatio': 0.3333,
      'productionBomPolicy': 'DIRECT_MAKE',
      'missingBom': false,
      'bomOverrideRequired': false,
      'hasActiveBom': false,
      'allocationPriority': 2,
    },
  ],
  'flatMaterials': [
    _materialJson(
      id: 'material-path-1',
      level: 2,
      path: ['测试产品', '组件 A', '共享紧固件'],
      routeConfirmed: routeConfirmed,
    ),
    _materialJson(
      id: 'material-path-2',
      level: 3,
      path: ['测试产品', '组件 B', '下层件', '共享紧固件'],
      routeConfirmed: routeConfirmed,
    ),
    {
      'materialLineId': 'dependency-path-1',
      'analysisLineId': 'product-line-1',
      'nodeKey': 'dependency-node-1',
      'actionGroupKey': 'dependency-action-1',
      'materialKey': 'dependency-goods||unit-1',
      'goodsId': 'dependency-goods',
      'goodsCode': 'D-1',
      'goodsName': '下层依赖件',
      'unitName': '个',
      'level': 3,
      'path': ['测试产品', '自制组件', '下层依赖件'],
      'requiredQty': 20,
      'allocatedAvailableQty': 4,
      'availableQty': 7,
      'shortageQty': 16,
      'sourceSuggestion': 'BUY',
      'routeConfirmed': false,
      'actionable': false,
    },
  ],
  'warehouses': [
    {'warehouseId': 'warehouse-1', 'warehouseName': '主仓'},
  ],
};

Map<String, dynamic> _buySelectionAnalysisJson() {
  final json = _analysisJson(const ['NOTIFY_SUPPLY']);
  json['flatMaterials'] = [
    _routeMaterial(
      id: 'buy-line-1',
      nodeKey: 'buy-node-1',
      actionGroupKey: 'buy-action-1',
      goodsCode: 'BUY-1',
      goodsName: '采购件一',
      route: 'BUY',
      controlStage: 'START',
    ),
    _routeMaterial(
      id: 'buy-line-2',
      nodeKey: 'buy-node-2',
      actionGroupKey: 'buy-action-2',
      goodsCode: 'BUY-2',
      goodsName: '采购件二',
      route: 'BUY',
      controlStage: 'FINISH',
    ),
    _routeMaterial(
      id: 'subcontract-line-1',
      nodeKey: 'subcontract-node-1',
      actionGroupKey: 'subcontract-action-1',
      goodsCode: 'SUB-1',
      goodsName: '委外件一',
      route: 'SUBCONTRACT',
      controlStage: 'ASSEMBLY',
    ),
  ];
  return json;
}

Map<String, dynamic> _buySelectionNotifiedAnalysisJson() {
  final json = _buySelectionAnalysisJson();
  final materials = (json['flatMaterials'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final notified = materials.firstWhere(
    (material) => material['materialLineId'] == 'buy-line-2',
  );
  notified['notifiedTargets'] = [
    {
      'target': 'BUY',
      'documentType': 'PURCHASE_REQUEST',
      'documentId': 'purchase-request-1',
      'status': 'CREATED',
    },
  ];
  return json;
}

Map<String, dynamic> _bulkRouteAnalysisJson({
  required int count,
  required List<String> allowedActions,
  int version = 3,
  String fingerprintChar = 'a',
  int confirmedCount = 0,
  int notifiedCount = 0,
}) {
  final json = _analysisJson(allowedActions)
    ..['version'] = version
    ..['fingerprint'] = fingerprintChar * 64;
  json['flatMaterials'] = [
    for (var index = 1; index <= count; index++)
      {
        'materialLineId': 'bulk-line-$index',
        'analysisLineId': 'product-line-1',
        'nodeKey': 'bulk-node-$index',
        'actionGroupKey': 'bulk-action-${index.toString().padLeft(3, '0')}',
        'materialKey': 'bulk-goods-$index||unit-1',
        'goodsId': 'bulk-goods-$index',
        'goodsCode': 'BULK-$index',
        'goodsName': '批量缺料 $index',
        'unitName': '个',
        'level': 1,
        'path': ['测试产品', '批量缺料 $index'],
        'requiredQty': 10,
        'allocatedAvailableQty': 2,
        'availableQty': 2,
        'shortageQty': 8,
        'sourceSuggestion': 'BUY',
        'sourceConfirmed': index <= confirmedCount ? 'BUY' : null,
        'routeConfirmed': index <= confirmedCount,
        'controlStage': 'START',
        'hardGate': true,
        'actionable': true,
        if (index <= notifiedCount)
          'notifiedTargets': [
            {
              'target': 'BUY',
              'documentType': 'PURCHASE_REQUEST',
              'documentId': 'bulk-purchase-request-$index',
              'status': 'CREATED',
            },
          ],
      },
  ];
  return json;
}

Map<String, dynamic> _makeTreeAnalysisJson() {
  final json = _analysisJson(const ['CONFIRM_ROUTES', 'NOTIFY_SUPPLY']);
  json['flatMaterials'] = [
    _routeMaterial(
      id: 'make-path-1',
      nodeKey: 'node-make-1',
      actionGroupKey: 'make-action-1',
      goodsCode: 'MAKE-A',
      goodsName: '自制组件 A',
      route: 'MAKE',
      controlStage: 'ASSEMBLY',
    ),
    {
      ..._routeMaterial(
        id: 'buy-child',
        nodeKey: 'node-buy-child',
        actionGroupKey: 'buy-child-action',
        goodsCode: 'BUY-CHILD',
        goodsName: '外箱依赖',
        route: 'BUY',
        controlStage: 'SHIP',
      ),
      'parentNodeKey': 'node-make-1',
      'level': 2,
    },
    _routeMaterial(
      id: 'make-path-2',
      nodeKey: 'node-make-2',
      actionGroupKey: 'make-action-2',
      goodsCode: 'MAKE-B',
      goodsName: '自制组件 A（另一 BOM 路径）',
      route: 'MAKE',
      controlStage: 'ASSEMBLY',
    ),
  ];
  return json;
}

Map<String, dynamic> _makeReadyChildAnalysisJson() {
  final json = _makeTreeAnalysisJson()
    ..['allowedActions'] = const ['NOTIFY_SUPPLY', 'GENERATE_PLAN'];
  final materials = json['flatMaterials']! as List<dynamic>;
  final makeMaterial = materials.cast<Map<String, dynamic>>().singleWhere(
    (material) => material['materialLineId'] == 'make-path-1',
  );
  makeMaterial['notifiedTargets'] = [
    {
      'target': 'MAKE',
      'documentType': 'PREPLAN_MAKE_TASK',
      'documentId': 'make-child-ready-1',
      'status': 'CREATED',
    },
  ];
  (json['products']! as List<dynamic>).add({
    'analysisLineId': 'make-child-ready-1',
    'sourceType': 'MAKE_COMPONENT',
    'parentAnalysisLineId': 'product-line-1',
    'parentGoodsName': '测试产品',
    'goodsId': 'goods-make-path-1',
    'goodsCode': 'MAKE-A',
    'goodsName': '自制组件 A（备料任务）',
    'unitName': '个',
    'requestedQty': 8,
    'submittedQty': 0,
    'approvedQty': 0,
    'remainingQty': 8,
    'readyNowQty': 8,
    'readinessRatio': 1,
    'productionBomPolicy': 'DIRECT_MAKE',
    'missingBom': false,
    'bomOverrideRequired': false,
    'hasActiveBom': false,
    'allocationPriority': 3,
  });
  return json;
}

/// 一个已通知自制的 depth-1 节点 + 关联的 MAKE_COMPONENT 子产品，用于验证
/// 待生产/生产中/已完工 状态推导（子产品 submitted/approved 驱动）。
Map<String, dynamic> _makeStatusAnalysisJson({
  double childSubmitted = 0,
  double childApproved = 0,
  double shortage = 8,
  String? planExecutionStatus,
  String? latestPlanId,
  String? latestPlanNo,
}) {
  final json = _analysisJson(const ['PLAN_PREVIEW', 'GENERATE_PLAN']);
  json['flatMaterials'] = [
    {
      'materialLineId': 'make-short-1',
      'analysisLineId': 'product-line-1',
      'nodeKey': 'node-make-short-1',
      'actionGroupKey': 'make-short-action',
      'materialKey': 'MAKE-SHORT||unit-1',
      'goodsId': 'goods-make-short',
      'goodsCode': 'MAKE-SHORT',
      'goodsName': '自制短缺件',
      'unitName': '个',
      'level': 1,
      'path': ['测试产品', '自制短缺件'],
      'requiredQty': 10,
      'allocatedAvailableQty': 2,
      'availableQty': 2,
      'shortageQty': shortage,
      'sourceSuggestion': 'MAKE',
      'sourceConfirmed': 'MAKE',
      'routeConfirmed': true,
      'controlStage': 'ASSEMBLY',
      'hardGate': true,
      'actionable': true,
      'notifiedTargets': [
        {
          'target': 'MAKE',
          'documentType': 'PREPLAN_MAKE_TASK',
          'documentId': 'child-line-1',
          'status': 'CREATED',
        },
      ],
    },
  ];
  json['products'] = [
    ...(json['products'] as List<dynamic>),
    {
      'analysisLineId': 'child-line-1',
      'sourceType': 'MAKE_COMPONENT',
      'parentAnalysisLineId': 'product-line-1',
      'parentGoodsName': '自制短缺件',
      'goodsId': 'goods-make-short',
      'goodsCode': 'MAKE-SHORT',
      'goodsName': '自制短缺件（自制备料）',
      'requestedQty': 8,
      'submittedQty': childSubmitted,
      'approvedQty': childApproved,
      'remainingQty': 8 - childApproved,
      'readyNowQty': 0,
      'planExecutionStatus': ?planExecutionStatus,
      'latestPlanId': ?latestPlanId,
      'latestPlanNo': ?latestPlanNo,
    },
  ];
  return json;
}

/// 两个产品共用同一种物料「共享电机」（两条独立 BOM 路径），外加一条未确认
/// 路线的独立件，用于验证按物料汇总视图的跨产品聚合、pegging 明细展开和
/// 逐路径勾选下达。
Map<String, dynamic> _aggregateAnalysisJson() {
  final json = _analysisJson(const ['NOTIFY_SUPPLY', 'REALLOCATE']);
  json['flatMaterials'] = [
    {
      'materialLineId': 'agg-path-1',
      'analysisLineId': 'product-line-1',
      'nodeKey': 'agg-node-1',
      'actionGroupKey': 'agg-action-1',
      'materialKey': 'goods-shared-motor||unit-1',
      'goodsId': 'goods-shared-motor',
      'goodsCode': 'MTR-1',
      'goodsName': '共享电机',
      'unitName': '个',
      'level': 1,
      'path': ['测试产品', '共享电机'],
      'requiredQty': 10,
      'allocatedAvailableQty': 4,
      'availableQty': 4,
      'shortageQty': 6,
      'sourceSuggestion': 'BUY',
      'sourceConfirmed': 'BUY',
      'routeConfirmed': true,
      'controlStage': 'START',
      'hardGate': true,
      'actionable': true,
    },
    {
      'materialLineId': 'agg-path-2',
      'analysisLineId': 'product-line-2',
      'nodeKey': 'agg-node-2',
      'actionGroupKey': 'agg-action-2',
      'materialKey': 'goods-shared-motor||unit-1',
      'goodsId': 'goods-shared-motor',
      'goodsCode': 'MTR-1',
      'goodsName': '共享电机',
      'unitName': '个',
      'level': 1,
      'path': ['第二测试产品', '共享电机'],
      'requiredQty': 5,
      'allocatedAvailableQty': 0,
      'availableQty': 4,
      'shortageQty': 5,
      'sourceSuggestion': 'BUY',
      'sourceConfirmed': 'BUY',
      'routeConfirmed': true,
      'controlStage': 'START',
      'hardGate': true,
      'actionable': true,
    },
    {
      'materialLineId': 'agg-path-3',
      'analysisLineId': 'product-line-1',
      'nodeKey': 'agg-node-3',
      'actionGroupKey': 'agg-action-3',
      'materialKey': 'goods-solo||unit-1',
      'goodsId': 'goods-solo',
      'goodsCode': 'SOLO-1',
      'goodsName': '独立件',
      'unitName': '个',
      'level': 1,
      'path': ['测试产品', '独立件'],
      'requiredQty': 8,
      'allocatedAvailableQty': 5,
      'availableQty': 5,
      'shortageQty': 3,
      'sourceSuggestion': 'BUY',
      'routeConfirmed': false,
      'controlStage': 'FINISH',
      'hardGate': true,
      'actionable': true,
    },
  ];
  return json;
}

/// 借用 4 件生效后的分析视图：agg-path-1（测试产品）被调走 4 件，
/// agg-path-2（第二测试产品）调入 4 件；双向明细可撤销。
Map<String, dynamic> _borrowedAnalysisJson() {
  final json = _aggregateAnalysisJson();
  final materials = (json['flatMaterials'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final from = materials.singleWhere(
    (material) => material['materialLineId'] == 'agg-path-1',
  );
  from['allocatedAvailableQty'] = 0;
  from['shortageQty'] = 10;
  from['borrowedOutQty'] = 4;
  from['borrowRefs'] = [
    {
      'borrowId': 'borrow-1',
      'direction': 'OUT',
      'qty': 4,
      'requestedQty': 4,
      'counterpartProduct': '第二测试产品',
      'reason': '客户加急，先保这单',
    },
  ];
  final to = materials.singleWhere(
    (material) => material['materialLineId'] == 'agg-path-2',
  );
  to['allocatedAvailableQty'] = 4;
  to['shortageQty'] = 1;
  to['borrowedInQty'] = 4;
  to['borrowRefs'] = [
    {
      'borrowId': 'borrow-1',
      'direction': 'IN',
      'qty': 4,
      'requestedQty': 4,
      'counterpartProduct': '测试产品',
      'reason': '客户加急，先保这单',
    },
  ];
  return json;
}

Map<String, dynamic> _routeMaterial({
  required String id,
  required String nodeKey,
  required String actionGroupKey,
  required String goodsCode,
  required String goodsName,
  required String route,
  required String controlStage,
}) => {
  'materialLineId': id,
  'analysisLineId': 'product-line-1',
  'nodeKey': nodeKey,
  'actionGroupKey': actionGroupKey,
  'materialKey': '$goodsCode||unit-1',
  'goodsId': 'goods-$id',
  'goodsCode': goodsCode,
  'goodsName': goodsName,
  'unitName': '个',
  'level': 1,
  'path': ['测试产品', goodsName],
  'requiredQty': 10,
  'allocatedAvailableQty': 2,
  'availableQty': 2,
  'shortageQty': 8,
  'sourceSuggestion': route,
  'sourceConfirmed': route,
  'routeConfirmed': true,
  'controlStage': controlStage,
  'hardGate': true,
  'actionable': true,
};

Map<String, dynamic> _materialJson({
  required String id,
  required int level,
  required List<String> path,
  required bool routeConfirmed,
}) => {
  'materialLineId': id,
  'analysisLineId': 'product-line-1',
  'nodeKey': id,
  'actionGroupKey': 'action-$id',
  'materialKey': 'goods-fastener||unit-1',
  'goodsId': 'goods-fastener',
  'goodsCode': 'M-1',
  'goodsName': '共享紧固件',
  'unitName': '个',
  'level': level,
  'path': path,
  'requiredQty': 16,
  'allocatedAvailableQty': 3,
  'availableQty': 3,
  'inboundQty': 2,
  'shortageQty': 11,
  'sourceSuggestion': 'BUY',
  'sourceConfirmed': routeConfirmed ? 'MAKE' : null,
  'routeConfirmed': routeConfirmed,
  'routeReason': routeConfirmed ? '交期紧急，改为车间自制' : null,
  'lowerLevelPending': false,
  'actionable': true,
};

class _Harness {
  const _Harness(this.requests);

  final List<RequestOptions> requests;
}
