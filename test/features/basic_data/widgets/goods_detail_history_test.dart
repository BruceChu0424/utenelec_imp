import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_app_bar_action_button.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/goods_operation_history.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_operation_history_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../../support/goods_bom_edit_test_api.dart';

GoodsDetail _detail(String name) => GoodsDetail(
  id: 'goods-a',
  code: 'G001',
  name: name,
  categoryId: 'category-a',
  status: '使用',
  sourceType: '自制',
  unitId: 'unit-a',
  unitName: '个',
  writable: true,
);

class _Goods extends Fake implements GoodsRepository {
  GoodsDetail value = _detail('原名称');
  Object? readError;
  Completer<void>? pendingSave;
  int writes = 0;
  int reads = 0;

  @override
  Future<GoodsDetail> detail(String id) async {
    reads++;
    if (readError != null) throw readError!;
    return value;
  }

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    writes++;
    await pendingSave?.future;
    value = _detail(body['name'] as String);
  }
}

class _Bom extends Fake implements GoodsBomRepository {
  int reads = 0;

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    reads++;
    return const [];
  }

  @override
  Future<GoodsBomLearningSummary> learning(String goodsId) async =>
      const GoodsBomLearningSummary();
}

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

class _History extends Fake implements GoodsOperationHistoryRepository {
  _History(this.goods);
  final _Goods goods;
  int undos = 0;
  int redos = 0;
  bool undone = false;
  bool removeOnUndo = false;

  GoodsOperationHistory get value => GoodsOperationHistory(
    entries: [
      GoodsOperationEntry(
        id: 'operation-a',
        operationType: 'GOODS_EDIT',
        label: '编辑货品',
        summary: 'G001 原名称',
        createdAt: '2026-10-20T00:00:00Z',
        state: undone ? 'UNDONE' : 'APPLIED',
        version: undone ? 2 : 1,
        affectedCount: 1,
        canUndo: !undone,
        canRedo: undone,
      ),
    ],
  );

  @override
  Future<GoodsOperationHistory> list() async => value;

  @override
  Future<GoodsOperationHistory> undo(
    String id, {
    required int expectedVersion,
  }) async {
    undos++;
    undone = true;
    goods.value = _detail('原名称');
    if (removeOnUndo) {
      goods.readError = ApiException('NOT_FOUND', '货品不存在');
    }
    return value;
  }

  @override
  Future<GoodsOperationHistory> redo(
    String id, {
    required int expectedVersion,
  }) async {
    redos++;
    undone = false;
    goods.readError = null;
    goods.value = _detail('已改名称');
    return value;
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Goods goods,
  _Bom bom,
  _History history, {
  GoodsDetailTab tab = GoodsDetailTab.basic,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1600, 1000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          Perm.goodsEdit,
          Perm.goodsBomCreate,
          Perm.goodsBomEdit,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'reader'),
        ),
        sessionSnapshotProvider.overrideWith(_Snapshots.new),
        apiBaseUrlProvider.overrideWithValue('https://company.invalid/api'),
        goodsRepositoryProvider.overrideWithValue(goods),
        goodsBomRepositoryProvider.overrideWithValue(bom),
        apiClientProvider.overrideWithValue(GoodsBomEditTestApi(bom)),
        goodsOperationHistoryRepositoryProvider.overrideWithValue(history),
        colorDictProvider.overrideWith((ref) async => const []),
        unitDictProvider.overrideWith(
          (ref) async => const [UnitListItem(id: 'unit-a', name: '个')],
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GoodsDetailBody(
            initialDetail: goods.value,
            initialCategoryId: null,
            initialTab: tab,
            canCreate: false,
            canEdit: true,
            canStatus: false,
            canBomCreate: true,
            canBomEdit: true,
            canBomDelete: false,
            onToggleStatus: null,
            onDelete: null,
            onDataChanged: null,
            onSaved: () => fail('已有货品保存应留在详情'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

bool _undoEnabled(WidgetTester tester) =>
    tester
        .widget<UtenAppBarActionButton>(
          find.byKey(const Key('goods-detail-history-undo')),
        )
        .onPressed !=
    null;

Future<void> _apply(WidgetTester tester, {bool cancel = false}) async {
  await tester.tap(find.byKey(const ValueKey('goods-history-apply')));
  await tester.pumpAndSettle();
  final dialog = find.byType(UtenAlertDialog);
  expect(dialog, findsOneWidget);
  await tester.tap(
    cancel
        ? find.descendant(of: dialog, matching: find.text('取消'))
        : find.descendant(of: dialog, matching: find.byType(FilledButton)),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('详情编辑保存后留在查看态，撤回和取消撤回都确认并重读详情', (tester) async {
    final goods = _Goods();
    final bom = _Bom();
    final history = _History(goods);
    await _pump(tester, goods, bom, history);

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(_undoEnabled(tester), isFalse);
    final form = tester.widget<MasterEditForm>(find.byType(MasterEditForm));
    expect(form.readOnlyKeys, isNot(contains('code')));
    expect(form.readOnlyKeys, contains('status'));
    final codeField = form.fields.singleWhere((field) => field.key == 'code');
    expect(codeField.readOnly, isFalse);
    expect(codeField.identifierDomain, 'GOODS');
    expect(codeField.identifierId, 'goods-a');
    final codeEditor = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller?.text == 'G001',
    );
    expect(codeEditor, findsOneWidget);
    expect(tester.widget<TextField>(codeEditor).readOnly, isFalse);
    final name = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.controller?.text == '原名称',
    );
    await tester.enterText(name, '已改名称');
    goods.pendingSave = Completer<void>();
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(_undoEnabled(tester), isFalse);
    goods.pendingSave!.complete();
    await tester.pumpAndSettle();
    expect(goods.writes, 1);
    expect(find.byType(MasterEditForm), findsNothing);
    expect(find.text('已改名称'), findsWidgets);
    expect(_undoEnabled(tester), isTrue);

    await tester.tap(find.byKey(const Key('goods-detail-history-undo')));
    await tester.pumpAndSettle();
    await _apply(tester, cancel: true);
    expect(history.undos, 0);
    await _apply(tester);
    expect(history.undos, 1);
    await tester.tap(find.byType(UtenCloseButton).last);
    await tester.pumpAndSettle();
    expect(find.text('原名称'), findsWidgets);

    await tester.tap(find.byKey(const Key('goods-detail-history-redo')));
    await tester.pumpAndSettle();
    await _apply(tester);
    expect(history.redos, 1);
    await tester.tap(find.byType(UtenCloseButton).last);
    await tester.pumpAndSettle();
    expect(find.text('已改名称'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消编辑丢弃本地修改，BOM 添加浮窗未结束时阻止历史重放', (tester) async {
    final goods = _Goods();
    final bom = _Bom();
    await _pump(tester, goods, bom, _History(goods));
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.controller?.text == '原名称',
      ),
      '未提交草稿',
    );
    await tester.tap(find.byKey(const Key('goods-detail-cancel-edit')));
    await tester.pumpAndSettle();
    expect(goods.writes, 0);
    expect(find.text('未提交草稿'), findsNothing);
    expect(_undoEnabled(tester), isTrue);
    await tester.tap(find.text('组装信息'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
    await enterBomEdit(tester);
    expect(_undoEnabled(tester), isFalse);
    await tester.tap(find.byKey(const Key('goods-bom-add-component')));
    await tester.pumpAndSettle();
    expect(find.byType(UtenFloatingWindow), findsOneWidget);
    expect(_undoEnabled(tester), isFalse);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(_undoEnabled(tester), isFalse);
    await saveBomEdit(tester);
    expect(_undoEnabled(tester), isTrue);
  });

  testWidgets('撤回后同时重载 BOM，货品不存在时隐藏旧详情且仍能取消撤回恢复', (tester) async {
    final goods = _Goods();
    final bom = _Bom();
    final history = _History(goods)..removeOnUndo = true;
    await _pump(tester, goods, bom, history, tab: GoodsDetailTab.bom);
    final readsBefore = bom.reads;
    await tester.tap(find.byKey(const Key('goods-detail-history-undo')));
    await tester.pumpAndSettle();
    await _apply(tester);
    await tester.tap(find.byType(UtenCloseButton).last);
    await tester.pumpAndSettle();
    expect(find.text('货品不存在'), findsOneWidget);
    expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);

    await tester.tap(find.byKey(const Key('goods-detail-history-redo')));
    await tester.pumpAndSettle();
    await _apply(tester);
    await tester.tap(find.byType(UtenCloseButton).last);
    await tester.pumpAndSettle();
    expect(bom.reads, greaterThan(readsBefore));
    expect(goods.reads, greaterThanOrEqualTo(2));
    expect(find.text('货品不存在'), findsNothing);
    expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
    expect(find.byKey(const Key('goods-bom-edit-mode')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
