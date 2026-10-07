import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/production/pages/production_over_limit_pages.dart';
import 'package:uten_imp/features/production/repositories/production_over_limit_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

ProductionOverLimitDisposition _detail({
  String name = '同批自制件',
  bool canDecide = true,
}) => ProductionOverLimitDisposition({
  'id': 'case',
  'status': 'PENDING',
  'rowVersion': 7,
  'canDecide': canDecide,
  'goodsName': name,
  'actualBatchQty': 1200,
  'withinAuthorizationQty': 1100,
  'overLimitQty': 100,
  'overLimitReason': '同一批多出',
  'unitName': '件',
});

class _Repository extends ProductionOverLimitRepository {
  _Repository() : super(ApiClient(Dio()));
  final reads = <Completer<ProductionOverLimitDisposition>>[];
  int decisions = 0;
  @override
  Future<ProductionOverLimitDisposition> detail(String id) {
    final completer = Completer<ProductionOverLimitDisposition>();
    reads.add(completer);
    return completer.future;
  }

  @override
  Future<ProductionOverLimitDisposition> decide(
    ProductionOverLimitDisposition source, {
    required String action,
    required String reason,
  }) async {
    decisions++;
    return _detail(canDecide: false);
  }
}

class _ListRepository extends _Repository {
  _ListRepository(this.row);
  final ProductionOverLimitDisposition row;
  @override
  Future<PagedResult<ProductionOverLimitDisposition>> list({
    String status = 'PENDING',
    int page = 1,
    int size = 20,
  }) async => PagedResult(
    items: [row],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );
}

Widget _precisionPage(ProductionOverLimitRepository repo, Widget page) =>
    ProviderScope(
      overrides: [
        productionOverLimitRepositoryProvider.overrideWithValue(repo),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionPlanApprove,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'planner'),
        ),
        apiBaseUrlProvider.overrideWith((ref) => 'https://server-a/api'),
      ],
      child: MaterialApp(home: page),
    );

void main() {
  for (final quantity in ['9999999999999.9999', '0.0001']) {
    testWidgets('处置详情与确认原样显示精确数量 $quantity', (tester) async {
      final repo = _Repository();
      await tester.pumpWidget(
        _precisionPage(repo, const ProductionOverLimitDetailPage(id: 'case')),
      );
      await tester.pump();
      repo.reads.single.complete(
        ProductionOverLimitDisposition({
          ..._detail().data,
          'actualBatchQty': quantity,
          'withinAuthorizationQty': '0',
          'overLimitQty': quantity,
          'plannedQty': quantity,
          'allowedRate': '0.000001',
        }),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('本批实际 $quantity · 额度内 0 · 本次超限 $quantity'),
        findsOneWidget,
      );
      expect(find.textContaining('报工时允许超产比例 0.0001%'), findsOneWidget);
      await tester.tap(find.text('接收为公共产出'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '已核对本批原始数量');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.textContaining('接收本批超限 $quantity 件'), findsOneWidget);
      expect(repo.decisions, 0);
      expect(tester.takeException(), isNull);
    });
    testWidgets('处置列表原样显示精确数量 $quantity', (tester) async {
      tester.view.physicalSize = const Size(2000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final row = ProductionOverLimitDisposition({
        ..._detail().data,
        'actualBatchQty': quantity,
        'withinAuthorizationQty': '0',
        'overLimitQty': quantity,
      });
      await tester.pumpWidget(
        _precisionPage(
          _ListRepository(row),
          const ProductionOverLimitListPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(quantity), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('已丢精度的旧大数回包显示未知并禁止确认', (tester) async {
    final repo = _Repository();
    await tester.pumpWidget(
      _precisionPage(repo, const ProductionOverLimitDetailPage(id: 'case')),
    );
    await tester.pump();
    repo.reads.single.complete(
      ProductionOverLimitDisposition({
        ..._detail().data,
        'overLimitQty': double.parse('9999999999999.9999'),
      }),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('本次超限 —'), findsOneWidget);
    expect(find.textContaining('本批数量未完整读取'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '接收为公共产出'), findsNothing);
    expect(repo.decisions, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all disposition decisions retain reasons people and times', (
    tester,
  ) async {
    final repo = _Repository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          productionOverLimitRepositoryProvider.overrideWithValue(repo),
          currentPermissionsProvider.overrideWithValue({
            Perm.productionPlanApprove,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'planner'),
          ),
          apiBaseUrlProvider.overrideWith((ref) => 'https://server-a/api'),
        ],
        child: const MaterialApp(
          home: ProductionOverLimitDetailPage(id: 'case'),
        ),
      ),
    );
    await tester.pump();
    repo.reads.single.complete(
      ProductionOverLimitDisposition({
        ..._detail(canDecide: false).data,
        'status': 'ACCEPTED',
        'plannedQty': 1000,
        'allowedRate': 0.1,
        'decisionReason': '全部转公共备货',
        'decidedByName': '计划丙',
        'decidedAt': '2026-10-07T10:00:00+08:00',
        'decisionHistory': [
          {
            'action': 'HOLD',
            'reason': '等待实物清点',
            'decidedByName': '计划甲',
            'decidedAt': '2026-10-07T08:00:00+08:00',
          },
          {
            'action': 'RETURN_FOR_REVIEW',
            'reason': '请车间核实计数',
            'decidedByName': '计划乙',
            'decidedAt': '2026-10-07T09:00:00+08:00',
          },
          {
            'action': 'ACCEPT_PUBLIC',
            'reason': '全部转公共备货',
            'decidedByName': '计划丙',
            'decidedAt': '2026-10-07T10:00:00+08:00',
          },
        ],
      }),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('报工时允许超产比例 10%'), findsOneWidget);
    expect(find.text('最新处理：全部转公共备货'), findsOneWidget);
    expect(
      find.textContaining('继续待处理 · 计划甲 · 2026-10-07 08:00\n等待实物清点'),
      findsOneWidget,
    );
    expect(
      find.textContaining('要求核实 · 计划乙 · 2026-10-07 09:00\n请车间核实计数'),
      findsOneWidget,
    );
    expect(
      find.textContaining('接收为公共产出 · 计划丙 · 2026-10-07 10:00\n全部转公共备货'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, '接收为公共产出'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'returning to the same server does not revive an old decision dialog',
    (tester) async {
      final repo = _Repository();
      final server = StateProvider((ref) => 'https://server-a/api');
      final container = ProviderContainer(
        overrides: [
          productionOverLimitRepositoryProvider.overrideWithValue(repo),
          currentPermissionsProvider.overrideWithValue({
            Perm.productionPlanApprove,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'planner'),
          ),
          apiBaseUrlProvider.overrideWith((ref) => ref.watch(server)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: ProductionOverLimitDetailPage(id: 'case'),
          ),
        ),
      );
      await tester.pump();
      repo.reads.single.complete(_detail());
      await tester.pumpAndSettle();
      await tester.tap(find.text('接收为公共产出'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '原服务器处理原因');
      container.read(server.notifier).state = 'https://server-b/api';
      await tester.pump();
      container.read(server.notifier).state = 'https://server-a/api';
      await tester.pump();
      expect(repo.reads, hasLength(3));
      repo.reads.last.complete(_detail());
      repo.reads[1].complete(_detail(name: '中间服务器'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(repo.decisions, 0);
      expect(find.text('确认审核'), findsNothing);
      await tester.tap(find.text('接收为公共产出'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField))
            .controller!
            .text,
        isEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final (permission, canDecide, readOnly) in [
    (false, true, false),
    (true, false, false),
    (true, true, true),
    (true, true, false),
  ]) {
    testWidgets(
      'decision requires local permission server capability and writable identity $permission/$canDecide/$readOnly',
      (tester) async {
        final repo = _Repository();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              productionOverLimitRepositoryProvider.overrideWithValue(repo),
              currentPermissionsProvider.overrideWithValue({
                if (permission) Perm.productionPlanApprove,
              }),
              isSuperAdminProvider.overrideWithValue(false),
              authenticatedScopeProvider.overrideWithValue(
                AuthenticatedScope(userId: 'planner', readOnly: readOnly),
              ),
              apiBaseUrlProvider.overrideWith((ref) => 'https://server-a/api'),
            ],
            child: const MaterialApp(
              home: ProductionOverLimitDetailPage(id: 'case'),
            ),
          ),
        );
        await tester.pump();
        repo.reads.single.complete(_detail(canDecide: canDecide));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('本批实际 1200 · 额度内 1100 · 本次超限 100'),
          findsOneWidget,
        );
        expect(
          find.text('接收为公共产出'),
          permission && canDecide && !readOnly ? findsOneWidget : findsNothing,
        );
        expect(find.textContaining('品质结果与仓库实收'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('late source-server response cannot overwrite current case', (
    tester,
  ) async {
    final repo = _Repository();
    final server = StateProvider((ref) => 'https://server-a/api');
    final container = ProviderContainer(
      overrides: [
        productionOverLimitRepositoryProvider.overrideWithValue(repo),
        currentPermissionsProvider.overrideWithValue({
          Perm.productionPlanApprove,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'planner'),
        ),
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(server)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ProductionOverLimitDetailPage(id: 'case'),
        ),
      ),
    );
    await tester.pump();
    expect(repo.reads, hasLength(1));
    container.read(server.notifier).state = 'https://server-b/api';
    await tester.pump();
    expect(repo.reads, hasLength(2));
    repo.reads.last.complete(_detail(name: '新服务器实物'));
    await tester.pumpAndSettle();
    repo.reads.first.complete(_detail(name: '旧服务器实物'));
    await tester.pumpAndSettle();
    expect(find.textContaining('新服务器实物'), findsOneWidget);
    expect(find.textContaining('旧服务器实物'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission revoked while entering reason prevents a decision', (
    tester,
  ) async {
    final repo = _Repository();
    final permissions = StateProvider<Set<String>>(
      (ref) => {Perm.productionPlanApprove},
    );
    final container = ProviderContainer(
      overrides: [
        productionOverLimitRepositoryProvider.overrideWithValue(repo),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(permissions),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'planner'),
        ),
        apiBaseUrlProvider.overrideWith((ref) => 'https://server-a/api'),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ProductionOverLimitDetailPage(id: 'case'),
        ),
      ),
    );
    await tester.pump();
    repo.reads.single.complete(_detail());
    await tester.pumpAndSettle();
    await tester.tap(find.text('接收为公共产出'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '留作公共备货');
    container.read(permissions.notifier).state = {};
    await tester.pump();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(repo.decisions, 0);
    expect(find.text('确认审核'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
