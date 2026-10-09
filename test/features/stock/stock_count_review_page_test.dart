import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/models/goods_issue_method.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_issue_method_repository.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/features/stock/counts/models/stock_count_request.dart';
import 'package:uten_imp/features/stock/counts/pages/stock_count_review_page.dart';
import 'package:uten_imp/features/stock/counts/repositories/stock_count_request_repository.dart';
import 'package:uten_imp/features/warehouse/materialbin/widgets/workshop_material_first_use_card.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

class _Repo implements StockCountRequestRepository {
  _Repo({this.stale = false, this.setupBasis, this.lineCount = 1});
  final bool stale;
  final String? setupBasis;
  final int lineCount;
  final queries = <({String? reviewRoute, String? status, int page})>[];
  final List<String> actions = const ['APPROVE', 'REJECT'];
  int reads = 0;
  int approvals = 0;
  String? reviewedReason;
  Completer<void>? detailGate;
  Completer<void>? approvalGate;
  StockCountRequest get request => StockCountRequest(
    id: 'count-1',
    requestNo: 'PD01',
    warehouseId: 'w',
    warehouseName: '原料仓',
    reviewRoute: 'FINANCE',
    status: 'PENDING',
    version: 7,
    submittedByName: '张三',
    reason: '月末盘点',
    allowedActions: actions,
    lines: [
      for (var i = 0; i < lineCount; i++)
        StockCountRequestLine(
          goodsId: i == 0 ? 'g' : 'g${i + 1}',
          goodsName: i == 0 ? '颗粒' : '颗粒${i + 1}',
          unitName: 'kg',
          beforeQty: '9007199254740993.0000',
          targetQty: '9007199254740994.0000',
          deltaQty: '1.0000',
          beforeWeightKg: '8.0000',
          targetWeightKg: '8.0000',
          currentQty: '9007199254740993.0000',
          stale: stale,
          materialSetupBasis: setupBasis,
          goodsVersion: 17,
        ),
    ],
  );
  @override
  Future<StockCountRequest> detail(String id) async {
    reads++;
    await detailGate?.future;
    return request;
  }

  @override
  Future<PagedResult<StockCountRequest>> list({
    String? reviewRoute,
    String? status,
    String? warehouseId,
    String? warehouseScope,
    String? scopeWarehouseId,
    String? keyword,
    int page = 1,
    int size = 50,
  }) async {
    reads++;
    queries.add((reviewRoute: reviewRoute, status: status, page: page));
    return PagedResult(
      items: approvals == 0 ? [request] : [],
      page: page,
      size: size,
      total: approvals == 0 ? 1 : 0,
      totalPages: 1,
    );
  }

  @override
  Future<StockCountRequest> approve(
    String id, {
    required int expectedVersion,
    required String idempotencyKey,
    String? reason,
  }) async {
    expect(expectedVersion, 7);
    expect(idempotencyKey, isNotEmpty);
    approvals++;
    reviewedReason = reason;
    await approvalGate?.future;
    return StockCountRequest(
      id: id,
      requestNo: 'PD01',
      warehouseId: 'w',
      warehouseName: '原料仓',
      reviewRoute: 'FINANCE',
      status: 'APPROVED',
      version: 8,
      lines: request.lines,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Preview implements GoodsIssueMethodRepository {
  _Preview({
    this.version = 17,
    this.goodsIdOverride,
    this.targetOverride,
    this.basisOverride,
    this.massUnit = true,
    this.canSwitch = true,
    this.blockers = const [],
    this.bomRows = const [
      GoodsIssueMethodBomRow(productName: '关联注塑件', action: 'REMOVE'),
    ],
  });
  final int? version;
  final String? goodsIdOverride;
  final String? targetOverride;
  final String? basisOverride;
  final bool massUnit;
  final bool canSwitch;
  final List<String> blockers;
  final List<GoodsIssueMethodBomRow> bomRows;
  String? basis;
  int calls = 0;
  bool failNext = false;
  Completer<void>? gate;
  @override
  Future<GoodsIssueMethodPreview> preview(
    String goodsId, {
    required String target,
    String? costBasis,
  }) async {
    calls++;
    basis = costBasis;
    await gate?.future;
    if (failNext) {
      failNext = false;
      throw StateError('预览暂时不可用');
    }
    return GoodsIssueMethodPreview(
      goodsId: goodsIdOverride ?? goodsId,
      targetIssueMethod: targetOverride ?? target,
      targetCostBasis: basisOverride ?? costBasis,
      version: version,
      massUnit: massUnit,
      canSwitch: canSwitch,
      blockers: blockers,
      bomRows: bomRows,
    );
  }

  @override
  Future<void> apply(List<GoodsIssueMethodChange> items) async =>
      throw StateError('盘点审核不能单独修改主档');
}

Future<void> _pump(
  WidgetTester tester,
  _Repo repo, {
  Set<String> permissions = const {Perm.stockCountFinanceReview},
  _Preview? preview,
  String? requestId = 'count-1',
  Size size = const Size(2000, 1000),
  double textScale = 1,
  VoidCallback? onChanged,
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        stockCountRequestRepositoryProvider.overrideWithValue(repo),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        goodsIssueMethodRepositoryProvider.overrideWithValue(
          preview ?? _Preview(),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: StockCountReviewPage(
          reviewRoute: 'FINANCE',
          requestId: requestId,
          onChanged: onChanged,
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

const _materialReviewPermissions = {
  Perm.stockCountFinanceReview,
  Perm.goodsEdit,
  Perm.goodsBomEdit,
};

void main() {
  testWidgets('审核列表使用顶部状态分类栏，切换后按状态重新取第一页', (tester) async {
    final repo = _Repo();
    await _pump(tester, repo, requestId: null);
    final toolbar = find.byType(UtenFilterToolbar<String>);
    expect(toolbar, findsOneWidget);
    expect(find.byType(UtenDropdownField), findsNothing);
    expect(repo.queries.last, (
      reviewRoute: 'FINANCE',
      status: 'PENDING',
      page: 1,
    ));
    await tester.tap(find.descendant(of: toolbar, matching: find.text('已驳回')));
    await tester.pumpAndSettle();
    expect(repo.queries.last, (
      reviewRoute: 'FINANCE',
      status: 'REJECTED',
      page: 1,
    ));
    expect(tester.widget<UtenFilterToolbar<String>>(toolbar).selected, {
      'REJECTED',
    });
    await tester.tap(find.descendant(of: toolbar, matching: find.text('全部')));
    await tester.pumpAndSettle();
    expect(repo.queries.last, (reviewRoute: 'FINANCE', status: null, page: 1));
  });

  testWidgets('审核操作悬浮在右下角，详情不重复长说明或撑满空白表格', (tester) async {
    final repo = _Repo(setupBasis: 'OWN');
    await _pump(
      tester,
      repo,
      permissions: {
        Perm.stockCountFinanceReview,
        Perm.goodsEdit,
        Perm.goodsBomEdit,
      },
    );
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(
      scaffold.floatingActionButtonLocation,
      FloatingActionButtonLocation.endFloat,
    );
    expect(scaffold.floatingActionButton, isA<UtenFloatingActionGroup>());
    final floating = find.byType(UtenFloatingActionGroup);
    expect(
      find.descendant(
        of: floating,
        matching: find.byKey(const Key('stock-count-approve')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: floating,
        matching: find.byKey(const Key('stock-count-reject')),
      ),
      findsOneWidget,
    );
    // 2026-10-08 用户口径：驳回红 / 通过绿，样式对齐全站审核页右下悬浮组。
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('stock-count-reject')))
          .type,
      UtenButtonType.danger,
    );
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('stock-count-approve')))
          .type,
      UtenButtonType.success,
    );
    expect(find.text('驳回'), findsOneWidget);
    expect(find.text('通过'), findsOneWidget);
    expect(find.text('仅变更的旧数值显示红色删除线；审核通过后才更新库存。'), findsNothing);
    expect(find.textContaining('本次盘点批准成功时会把该货品统一改为整批领料'), findsNothing);
    expect(find.textContaining('用途影响所有车间和后续任务'), findsNothing);
    expect(find.text('确认用途及关联 BOM 调整'), findsNothing);
    expect(find.byType(WorkshopMaterialFirstUseCard), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.byType(UtenDropdownField), findsNothing);
    final tableSize = tester.getSize(
      find.byType(MasterDataTableView<StockCountRequestLine>),
    );
    expect(tableSize.height, lessThan(400));
    final fab = tester.getRect(floating);
    expect(fab.right, greaterThan(1900));
    expect(fab.bottom, greaterThan(900));
  });

  testWidgets('窄屏大字体自动核对全部材料，无需选择且悬浮审核按钮可操作', (tester) async {
    final repo = _Repo(setupBasis: 'OWN', lineCount: 2);
    final preview = _Preview();
    await _pump(
      tester,
      repo,
      permissions: _materialReviewPermissions,
      preview: preview,
      size: const Size(375, 650),
      textScale: 1.3,
    );
    expect(tester.takeException(), isNull);
    final approve = find.byKey(const Key('stock-count-approve'));
    expect(preview.calls, 2);
    expect(find.byType(WorkshopMaterialFirstUseCard), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(tester.widget<UtenButton>(approve).onPressed, isNotNull);
    final fab = tester.getRect(find.byType(UtenFloatingActionGroup));
    expect(fab.left, greaterThanOrEqualTo(0));
    expect(fab.right, lessThanOrEqualTo(375));
    expect(fab.bottom, lessThanOrEqualTo(650));
    await tester.tap(approve);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stock-count-review-confirm')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未授权不读取审核数据，旧库存权限不能打开审核入口', (tester) async {
    final repo = _Repo();
    await _pump(tester, repo, permissions: {Perm.stockBalanceAdjust});
    expect(repo.reads, 0);
    expect(find.text('未获本页盘点授权'), findsOneWidget);
    expect(find.byKey(const Key('stock-count-approve')), findsNothing);
  });

  testWidgets('只给变更旧数值删除线，未修改重量和整行不染色', (tester) async {
    final repo = _Repo();
    await _pump(tester, repo);
    final old = tester.widget<Text>(find.text('9007199254740993.0000').first);
    expect(old.style?.decoration, TextDecoration.lineThrough);
    expect(find.text('9007199254740994.0000'), findsOneWidget);
    final weight = tester.widget<Text>(find.text('8.0000').first);
    expect(weight.style?.decoration, isNot(TextDecoration.lineThrough));
    final table = tester.widget<MasterDataTableView<StockCountRequestLine>>(
      find.byType(MasterDataTableView<StockCountRequestLine>),
    );
    expect(table.rowColor, isNull);
    expect(
      table.columns.map((c) => c.label),
      containsAll(['原数量', '盘点数量', '数量差额']),
    );
  });

  testWidgets('审核用当前版本提交，成功后自动返回并刷新列表及父级通知', (tester) async {
    final repo = _Repo();
    var changes = 0;
    await _pump(tester, repo, onChanged: () => changes++);
    await tester.tap(find.byKey(const Key('stock-count-approve')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stock-count-review-confirm')));
    await tester.pumpAndSettle();
    expect(repo.approvals, 1);
    expect(changes, 1);
    expect(find.byKey(const Key('stock-count-approve')), findsNothing);
    expect(
      find.byType(MasterDataTableView<StockCountRequestLine>),
      findsNothing,
    );
    expect(find.byType(UtenFilterToolbar<String>), findsOneWidget);
    expect(repo.queries, [
      (reviewRoute: 'FINANCE', status: 'PENDING', page: 1),
    ]);
    final table = tester.widget<MasterDataTableView<StockCountRequest>>(
      find.byType(MasterDataTableView<StockCountRequest>),
    );
    expect(table.items, isEmpty, reason: '通过后的申请不继续留在待审核列表');
  });

  testWidgets('提交后库存变化不能通过，但允许驳回', (tester) async {
    final repo = _Repo(stale: true);
    await _pump(tester, repo);
    expect(find.textContaining('提交后库存已变化'), findsOneWidget);
    await tester.tap(find.byKey(const Key('stock-count-approve')));
    await tester.pump();
    expect(find.byKey(const Key('stock-count-review-confirm')), findsNothing);
    expect(repo.approvals, 0);
    expect(find.byKey(const Key('stock-count-reject')), findsOneWidget);
  });

  testWidgets('数值相同但小数位不同不画删除线', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: StockCountOldValue(before: '1.0000', after: '1'),
      ),
    );
    expect(
      tester.widget<Text>(find.text('1.0000')).style?.decoration,
      isNot(TextDecoration.lineThrough),
    );
  });

  testWidgets('首次材料按申请用途自动核对，直接通过无需勾选或修改主档', (tester) async {
    final repo = _Repo(setupBasis: 'SHARED');
    final preview = _Preview();
    await _pump(
      tester,
      repo,
      permissions: _materialReviewPermissions,
      preview: preview,
    );
    expect(preview.basis, 'SHARED');
    expect(preview.calls, 1);
    expect(find.byType(UtenDropdownField), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(WorkshopMaterialFirstUseCard), findsNothing);
    final table = tester.widget<MasterDataTableView<StockCountRequestLine>>(
      find.byType(MasterDataTableView<StockCountRequestLine>),
    );
    expect(
      table.columns
          .singleWhere((column) => column.key == 'basis')
          .value(repo.request.lines.single),
      '辅料',
    );
    expect(
      table.columns.map((column) => column.key),
      contains('materialImpact'),
    );
    final approve = find.byKey(const Key('stock-count-approve'));
    expect(tester.widget<UtenButton>(approve).onPressed, isNotNull);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stock-count-review-confirm')), findsOneWidget);
    expect(repo.approvals, 0, reason: '进入整单审核确认前后均不单独写主档或库存');
    await tester.tap(find.byKey(const Key('stock-count-review-confirm')));
    await tester.pumpAndSettle();
    expect(repo.approvals, 1);
  });

  testWidgets('材料影响在表格中可打开只读详情，无需确认用途', (tester) async {
    await _pump(
      tester,
      _Repo(setupBasis: 'SHARED'),
      permissions: _materialReviewPermissions,
    );
    final impact = find.byKey(const Key('stock-count-impact-g'));
    await tester.ensureVisible(impact);
    await tester.tap(impact);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('关联 BOM 1 行，其中 1 行将调整'));
    await tester.pumpAndSettle();
    expect(find.textContaining('关联注塑件'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(UtenDropdownField), findsNothing);
    expect(find.text('确认用途及关联 BOM 调整'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('只有盘点审核权而无主档权限不能批准首次材料接入', (tester) async {
    final repo = _Repo(setupBasis: 'OWN');
    await _pump(tester, repo);
    await tester.tap(find.byKey(const Key('stock-count-approve')));
    await tester.pump();
    expect(find.byKey(const Key('stock-count-review-confirm')), findsNothing);
    expect(repo.approvals, 0);
  });

  testWidgets('刷新同一版本详情也重新核对材料影响，等待期间不能批准', (tester) async {
    final repo = _Repo(setupBasis: 'OWN');
    final preview = _Preview();
    await _pump(
      tester,
      repo,
      permissions: _materialReviewPermissions,
      preview: preview,
    );
    final approve = find.byKey(const Key('stock-count-approve'));
    expect(tester.widget<UtenButton>(approve).onPressed, isNotNull);
    expect(preview.calls, 1);
    final gate = Completer<void>();
    preview.gate = gate;
    await tester.tap(find.byTooltip('刷新'));
    await tester.pump();
    expect(repo.reads, 2);
    expect(preview.calls, 2);
    expect(tester.widget<UtenButton>(approve).onPressed, isNull);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<UtenButton>(approve).onPressed, isNotNull);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('货品版本变化后不能批准旧申请', (tester) async {
    final repo = _Repo(setupBasis: 'OWN');
    await _pump(
      tester,
      repo,
      permissions: _materialReviewPermissions,
      preview: _Preview(version: 18),
    );
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('stock-count-approve')))
          .onPressed,
      isNull,
    );
    expect(repo.approvals, 0);
    final impact = find.byKey(const Key('stock-count-impact-g'));
    await tester.ensureVisible(impact);
    await tester.tap(impact);
    await tester.pumpAndSettle();
    expect(find.textContaining('申请后货品版本已变化'), findsWidgets);
  });

  for (final invalidPreview in <String, _Preview>{
    '不同货品': _Preview(goodsIdOverride: 'other-goods'),
    '不同领料方式': _Preview(targetOverride: 'ORDER'),
    '不同申请用途': _Preview(basisOverride: 'EXPENSE'),
    '缺失货品版本': _Preview(version: null),
    '非重量单位': _Preview(massUnit: false),
    '服务端禁止切换': _Preview(canSwitch: false),
    '服务端存在阻断项': _Preview(blockers: ['仍有未核清的领料需求']),
    '关联 BOM 必须先修复': _Preview(
      bomRows: const [
        GoodsIssueMethodBomRow(
          productName: '需修复的注塑件',
          action: GoodsIssueMethodBomRow.actionBlocked,
        ),
      ],
    ),
  }.entries) {
    testWidgets('自动核对保留安全校验：${invalidPreview.key}不能批准但可以驳回', (tester) async {
      final repo = _Repo(setupBasis: 'OWN');
      await _pump(
        tester,
        repo,
        permissions: _materialReviewPermissions,
        preview: invalidPreview.value,
      );
      expect(
        tester
            .widget<UtenButton>(find.byKey(const Key('stock-count-approve')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<UtenButton>(find.byKey(const Key('stock-count-reject')))
            .onPressed,
        isNotNull,
      );
      expect(repo.approvals, 0);
    });
  }

  testWidgets('材料影响读取失败时不能通过，在表格重试成功后自动恢复审核', (tester) async {
    final repo = _Repo(setupBasis: 'OWN');
    final preview = _Preview()..failNext = true;
    await _pump(
      tester,
      repo,
      permissions: _materialReviewPermissions,
      preview: preview,
    );
    final approve = find.byKey(const Key('stock-count-approve'));
    expect(tester.widget<UtenButton>(approve).onPressed, isNull);
    expect(preview.calls, 1);
    final impact = find.byKey(const Key('stock-count-impact-g'));
    await tester.ensureVisible(impact);
    await tester.tap(impact);
    await tester.pumpAndSettle();
    expect(preview.calls, 2);
    expect(tester.widget<UtenButton>(approve).onPressed, isNotNull);
    expect(repo.approvals, 0);
    expect(find.byType(WorkshopMaterialFirstUseCard), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('首次读取及审核提交等待时不显示顶部加载条，重复审核被禁用', (tester) async {
    final detailGate = Completer<void>();
    final approvalGate = Completer<void>();
    final repo = _Repo()
      ..detailGate = detailGate
      ..approvalGate = approvalGate;
    await _pump(tester, repo, settle: false);
    expect(repo.reads, 1);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    detailGate.complete();
    await tester.pumpAndSettle();
    final approve = find.byKey(const Key('stock-count-approve'));
    await tester.tap(approve);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stock-count-review-confirm')));
    await tester.pump();
    expect(repo.approvals, 1);
    expect(tester.widget<UtenButton>(approve).onPressed, isNull);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    approvalGate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byKey(const Key('stock-count-approve')), findsNothing);
  });
}
