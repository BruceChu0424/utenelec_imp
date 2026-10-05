import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/warehouse/models/inbound_registration_line.dart';
import 'package:uten_imp/features/warehouse/pages/production_finished_arrival_registration_page.dart';
import 'package:uten_imp/features/warehouse/providers/inbound_warehouse_fill_memory.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_place_suggestion_repository.dart';
import 'package:uten_imp/features/warehouse/widgets/inbound_registration_widgets.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/uten_page_prefs_notifier.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';

import '../../shared/drafts/memory_form_draft_storage.dart';

const _reportA = '20000000-0000-0000-0000-000000000001';
const _reportB = '20000000-0000-0000-0000-000000000002';
const _itemA = '30000000-0000-0000-0000-000000000001';
const _itemB = '30000000-0000-0000-0000-000000000002';
const _itemA2 = '30000000-0000-0000-0000-000000000003';
const _goodsA = 'a0000000-0000-0000-0000-000000000001';
const _goodsB = 'a0000000-0000-0000-0000-000000000002';
const _goodsA2 = 'a0000000-0000-0000-0000-000000000003';

const _inspectSubmitKey = Key('inbound-route-submit-inspectFirst');
const _stockInSubmitKey = Key('inbound-route-submit-stockInFirst');

/// 共用库位建议端点的桩数据：仓 → 货品 → (库位, 来源)。
const _placeSuggestions = <String, Map<String, (String, String)>>{
  'warehouse-1': {
    _goodsA: ('WH-A-01', 'WAREHOUSE_PREFERENCE'),
    _goodsA2: ('WH-A-02', 'WAREHOUSE_PREFERENCE'),
    _goodsB: ('WH-B-01', 'GOODS_MASTER'),
  },
  'warehouse-2': {_goodsA: ('BY-A-09', 'WAREHOUSE_PREFERENCE')},
};

final _testBatchPermissionsProvider =
    NotifierProvider<_TestBatchPermissions, Set<String>>(
      _TestBatchPermissions.new,
    );

class _TestBatchPermissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  void replace(Set<String> permissions) => state = permissions;
}

void main() {
  testWidgets(
    'each goods master warehouse takes precedence over personal last selection',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // A 的货品主档归属仓 = 备用成品仓；账号记忆 = 成品仓。
      // A 取归属仓(主档优先)，B 没有归属仓才兜底取账号记忆。
      final api = _BatchArrivalApi(
        goodsWarehouseDefaults: {_itemA: 'warehouse-2'},
      );
      await _openBatchPage(tester, api: api);
      expect(api.suggestionRequests.toSet(), {'warehouse-1', 'warehouse-2'});
      expect(
        find.descendant(
          of: _warehouseCell(_itemA),
          matching: find.text('备用成品仓'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _warehouseCell(_itemB), matching: find.text('成品仓')),
        findsOneWidget,
      );
      // 预填仓一律黄框待核对。
      expect(_warehouseDecoration(tester, _itemA).autofilled, isTrue);
      expect(_warehouseDecoration(tester, _itemB).autofilled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an unavailable master warehouse is not restored from an old per-goods history',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _BatchArrivalApi(
        goodsWarehouseDefaults: {_itemA: 'disabled-or-removed'},
      );
      await _openBatchPage(tester, api: api, rememberedWarehouseId: null);
      expect(api.suggestionRequests, isEmpty);
      expect(find.text('必选 · 点击选择'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'batch place suggestions remain yellow on focus and become manual only after text changes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _openBatchPage(tester, api: _BatchArrivalApi());
      final field = _placeField(_itemA);
      UtenInputDecoration decoration() =>
          tester.widget<TextField>(field).decoration! as UtenInputDecoration;
      // 共用库位列：建议值黄框，格内 ⓘ 说明建议来源(该仓记住的库位)。
      expect(decoration().autofilled, isTrue);
      expect(
        decoration().info,
        InboundPlaceSource.warehousePreference.reviewHint,
      );
      await tester.showKeyboard(field);
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: field, matching: find.byType(EditableText)),
            )
            .focusNode
            .hasFocus,
        isTrue,
      );
      tester.widget<TextField>(field).controller!.selection =
          const TextSelection.collapsed(offset: 0);
      await tester.pump();
      expect(decoration().autofilled, isTrue);
      await tester.enterText(field, 'MANUAL-B');
      await tester.pump();
      expect(decoration().autofilled, isFalse);
      expect(decoration().info, isNull);
    },
  );

  testWidgets('正式批量登记页响应 stock_doc:approve 动态授予与撤销', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    SharedPreferences.setMockInitialValues({});
    final api = _BatchArrivalApi();
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_testBatchPermissionsProvider),
        ),
        isSuperAdminProvider.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: ProductionFinishedArrivalRegistrationPage(
            reportIds: [_reportA, _reportB],
            route: InboundRoute.inspectFirst,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(_inspectSubmitKey), findsNothing);

    container.read(_testBatchPermissionsProvider.notifier).replace({
      Perm.stockDocApprove,
    });
    await tester.pumpAndSettle();
    expect(find.byKey(_inspectSubmitKey), findsOneWidget);
    expect(find.byKey(_stockInSubmitKey), findsNothing);
    expect(
      tester
          .widgetList<Checkbox>(find.byType(Checkbox))
          .any((checkbox) => checkbox.onChanged != null),
      isTrue,
    );

    container.read(_testBatchPermissionsProvider.notifier).replace(const {});
    await tester.pumpAndSettle();
    expect(find.byKey(_inspectSubmitKey), findsNothing);
  });

  testWidgets('批量自制登记可右键移出任意明细且只提交表内剩余报工行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchArrivalApi();
    await _openBatchPage(tester, api: api);

    // 2026-09-18 明细默认全选：先点表头清空选择，右键目标行时选中集才只剩它
    //(菜单计数 (1))；移出后再回选全部剩余行提交。
    await _toggleSelectAll(tester);
    final removedPlace = _placeField(_itemB);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('两极插套')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pump();
    await tester.tap(find.text('移出本次登记 (1)').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('返回任务中心后仍保持待登记'), findsOneWidget);
    await tester.tap(find.text('确认移出'));
    await tester.pumpAndSettle();
    expect(removedPlace, findsNothing);
    expect(find.textContaining('这些报工行未写入，仍在待登记'), findsOneWidget);
    await _toggleSelectAll(tester);

    _pressSubmit(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认登记送检'));
    await tester.pumpAndSettle();
    final lots = (api.lastPostBody?['lots'] as List)
        .cast<Map<String, dynamic>>();
    expect(lots, hasLength(1));
    expect(lots.single['lotId'], _itemA);
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量登记页合并多报工明细、预选记忆仓、按单分组提交(库位记忆由服务端随登记完成)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchArrivalApi();
    await _openBatchPage(tester, api: api);

    expect(find.text('登记实际入库'), findsOneWidget);
    expect(find.text('路线：先质检后入库'), findsOneWidget);
    expect(find.text('RB202608300001'), findsOneWidget);
    expect(find.text('RB202608300002'), findsOneWidget);
    // 共用列：列名/列序与采购到货批量页一致；先质检后入库不显示「本次实收」。
    expect(_grid(tester).columns.map((column) => column.label), [
      '来源报工单',
      '货品名称',
      '编号',
      '颜色',
      '报工数量',
      '其中',
      '单位',
      '实称重量(kg)',
      '称重核对',
      '入库仓库',
      '库位号',
    ]);
    // ADR-148：一批实物里需求份 / 实际超产各多少，服务端算好直接显示。
    expect(find.text('需求 8 · 实际超产 2'), findsOneWidget);
    // 不再有「同时记住」开关：登记成功后服务端自动记住库位。
    expect(find.textContaining('同时记住'), findsNothing);

    // 账号记忆的上次所选仓落到全部行，并按仓拉了库位建议。
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
    // 2026-09-18 默认全选会让行内改库位整批落值：先清空选择改 B 行，再回选全部。
    await _toggleSelectAll(tester);
    await tester.enterText(_placeField(_itemB), 'CP-B-02');
    await _toggleSelectAll(tester);
    _pressSubmit(tester);
    await tester.pumpAndSettle();
    expect(api.lastPostPath, isNull);
    expect(find.text('先质检后入库(2 张报工单)'), findsOneWidget);
    expect(find.byType(InboundConfirmPoints), findsOneWidget);
    expect(find.text('确认登记并先入库'), findsNothing);
    await tester.tap(find.text('确认登记送检'));
    await tester.pumpAndSettle();

    expect(
      api.lastPostPath,
      '/warehouse/production-finished-in/arrival-registrations/batch',
    );
    final body = api.lastPostBody!;
    expect(body['idempotencyKey'], isA<String>());
    expect(body['idempotencyKey'] as String, isNot(endsWith(':prestock')));
    expect(body.containsKey('stockInBeforeInspection'), isFalse);
    // 两张报工的两批实物一个命令提交；分组(报工 x 实际仓)由服务端做。
    final lots = (body['lots'] as List).cast<Map<String, dynamic>>();
    expect(lots.map((lot) => lot['lotId']), [_itemA, _itemB]);
    for (final lot in lots) {
      expect(lot['warehouseId'], 'warehouse-1');
      expect(lot.containsKey('countedQty'), isFalse);
    }
    expect(lots.first['place'], 'WH-A-01');
    expect(lots.last['place'], 'CP-B-02');
    // 记忆随登记事务在服务端完成：除库位建议、单重参数(称重核对，ADR-135)与登记本身外
    // 不再有单独的记忆请求。
    expect(api.postPaths.toSet(), {
      '/warehouse/place-suggestions',
      '/stock/weight/params',
      '/warehouse/production-finished-in/arrival-registrations/batch',
    });
    expect(tester.takeException(), isNull);
  });

  // ADR-151 §1 回归 (2026-10-04 用户「多选就报错」): 开着本机草稿保护, 取消勾选再勾回
  // (快照回到初始值) 后提交必须照常发出批量登记, 不能撞「草稿已在其他页面删除」。
  testWidgets('草稿保护开启时取消勾选再勾回后提交仍发出批量登记', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchArrivalApi();
    final drafts = MemoryFormDraftStorage();
    final container = await _openBatchPage(
      tester,
      api: api,
      drafts: drafts,
      permissions: const {Perm.stockDocApprove, Perm.stockDocView},
    );

    await _toggleSelectAll(tester);
    await tester.pumpAndSettle();
    expect(drafts.records, isNotEmpty, reason: '取消勾选后已自动保存本机草稿');
    await _toggleSelectAll(tester);
    await tester.pumpAndSettle();
    final record =
        jsonDecode(drafts.records.values.single) as Map<String, dynamic>;
    expect(record['completed'], isNot(true), reason: '回到初始值不写删除墓碑');

    _pressSubmit(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认登记送检'));
    await tester.pumpAndSettle();
    expect(
      api.lastPostPath,
      '/warehouse/production-finished-in/arrival-registrations/batch',
    );
    expect(
      container.read(appNotificationProvider).map((n) => n.message),
      isNot(contains('批量登记失败，请保持当前内容后重试')),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量登记备注 trim 后随批提交；右键批量设置库位号应用到全部选中行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchArrivalApi();
    await _openBatchPage(tester, api: api);

    await tester.enterText(
      find.byKey(const Key('production-finished-arrival-remark')),
      '  整托入库  ',
    );
    // 2026-09-12 表头上方「全选/统一设置成品仓/统一填写库位/移出」按钮全撤：
    // 全选走表头复选框，批量填库位走右键菜单。
    // 2026-09-18 明细默认全选，无需再点表头(再点反而会清空选择)。
    expect(find.text('全选'), findsNothing);
    expect(find.text('统一填写库位(0)'), findsNothing);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('三极插套')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pump();
    expect(find.text('批量设置入库仓库 (2)'), findsOneWidget);
    await tester.tap(find.text('批量设置库位号 (2)'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('production-finished-arrival-batch-place-input')),
      'RACK-9',
    );
    await tester.tap(
      find.byKey(const Key('production-finished-arrival-batch-place-apply')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(_placeField(_itemA)).controller?.text,
      'RACK-9',
    );
    expect(
      tester.widget<TextField>(_placeField(_itemB)).controller?.text,
      'RACK-9',
    );
    expect(
      (tester.widget<TextField>(_placeField(_itemB)).decoration!
              as UtenInputDecoration)
          .autofilled,
      isFalse,
    );

    // 右键菜单动作完成后选择集被清空(避免残留高亮)：回选全部行再提交
    //(2026-09-18 提交集=勾选集)。
    await _toggleSelectAll(tester);

    _pressSubmit(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认登记送检'));
    await tester.pumpAndSettle();
    final body = api.lastPostBody!;
    expect(body['remark'], '整托入库');
    for (final lot in (body['lots'] as List).cast<Map<String, dynamic>>()) {
      expect(lot['place'], 'RACK-9');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一报工的两批实物可以进不同仓，一个命令提交', (tester) async {
    // 实称重量/称重核对两列加宽了表格：放宽视口让入库仓库格落在屏内。
    // 「其中」列再加宽了表格：放宽视口让入库仓库格落在屏内。
    await tester.binding.setSurfaceSize(const Size(2000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // 报工 A 有两行明细；无账号记忆仓 → 行上仓为空，逐行选择不同仓。
    final api = _BatchArrivalApi(twoItemsInFirstReport: true);
    await _openBatchPage(tester, api: api, rememberedWarehouseId: null);
    await tester.pumpAndSettle();

    // 2026-09-18 默认全选会让逐行选仓整批落值：先清空选择再做单行操作，
    // 全部行就位后回选全部再提交。
    await _toggleSelectAll(tester);

    // 报工 A 两行分别选不同仓；报工 B 的行也分配好仓与库位(不参与冲突)。
    // 2026-09-12 表头默认仓下拉已撤：未选行格内文案为「必选 · 点击选择」。
    await tester.tap(find.text('必选 · 点击选择').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('成品仓').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('必选 · 点击选择').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('备用成品仓').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('必选 · 点击选择').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('成品仓').last);
    await tester.pumpAndSettle();

    await tester.enterText(_placeField(_itemA), 'CP-A-01');
    await tester.enterText(_placeField(_itemA2), 'CP-A-02');
    await tester.enterText(_placeField(_itemB), 'CP-B-01');
    // 回选全部行(提交集=勾选集)。
    await _toggleSelectAll(tester);
    // ADR-151 §5：一张报工按实际仓分成几个登记批次由服务端做，页面不再拦。
    _pressSubmit(tester);
    await tester.pumpAndSettle();
    expect(find.text('先质检后入库(2 张报工单)'), findsOneWidget);
    await tester.tap(find.text('确认登记送检'));
    await tester.pumpAndSettle();
    final lots = (api.lastPostBody!['lots'] as List)
        .cast<Map<String, dynamic>>();
    expect(
      {for (final lot in lots) lot['lotId']: lot['warehouseId']},
      {_itemA: 'warehouse-1', _itemA2: 'warehouse-2', _itemB: 'warehouse-1'},
    );
    // 登记成功回到宿主页(不再有「只能登记到一个仓」的拦截)。
    expect(find.byKey(const Key('open-batch-registration')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('库位建议走共用 POST /warehouse/place-suggestions；改仓清库位并重拉建议', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchArrivalApi();
    final container = await _openBatchPage(tester, api: api);

    // 进页：同仓的全部行合并成一个请求，按「货品 × 颜色」取建议。
    expect(api.suggestionBodies, hasLength(1));
    expect(api.suggestionBodies.single, {
      'warehouseId': 'warehouse-1',
      'items': [
        {'goodsId': _goodsA, 'colorId': null},
        {'goodsId': _goodsB, 'colorId': null},
      ],
    });
    // 旧的逐页 GET 建议端点与 last-warehouse 端点已下线。
    expect(
      api.getPaths.where(
        (path) =>
            path.endsWith('/place-suggestions') ||
            path.endsWith('/last-warehouse'),
      ),
      isEmpty,
    );
    expect(
      tester.widget<TextField>(_placeField(_itemB)).controller?.text,
      'WH-B-01',
    );
    expect(
      (tester.widget<TextField>(_placeField(_itemB)).decoration!
              as UtenInputDecoration)
          .info,
      InboundPlaceSource.goodsMaster.reviewHint,
    );

    // 只改 A 行：先清空默认全选，A 行手填库位后改仓——库位属于仓库，
    // 换仓一律清掉(含手填)，再按新仓的建议回填黄框。
    await _toggleSelectAll(tester);
    await tester.enterText(_placeField(_itemA), 'HAND-A');
    await tester.pump();
    expect(
      (tester.widget<TextField>(_placeField(_itemA)).decoration!
              as UtenInputDecoration)
          .autofilled,
      isFalse,
    );
    // 输入框聚焦后页面滚动会让格子落到吸顶表头下方：直接触发格子的点击回调。
    tester.widget<InkWell>(_warehouseCell(_itemA)).onTap!();
    await tester.pumpAndSettle();
    await tester.tap(find.text('备用成品仓').last);
    await tester.pumpAndSettle();

    expect(api.suggestionBodies, hasLength(2));
    expect(api.suggestionBodies.last, {
      'warehouseId': 'warehouse-2',
      'items': [
        {'goodsId': _goodsA, 'colorId': null},
      ],
    });
    final placeA = tester.widget<TextField>(_placeField(_itemA));
    expect(placeA.controller?.text, 'BY-A-09');
    expect((placeA.decoration! as UtenInputDecoration).autofilled, isTrue);
    // 显式选的仓：不再是预填黄框，并记进账号记忆(下次登记兜底预填)。
    expect(_warehouseDecoration(tester, _itemA).autofilled, isFalse);
    expect(
      container
          .read(inboundWarehouseFillMemoryProvider(InboundFillScope.finished))
          .warehouseId,
      'warehouse-2',
    );
    // B 行不受影响。
    expect(
      tester.widget<TextField>(_placeField(_itemB)).controller?.text,
      'WH-B-01',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('先入库后质检进页：路线锁定、只显示该路线提交按钮、实收须等于报工数量', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _BatchArrivalApi();
    await _openBatchPage(
      tester,
      api: api,
      stockInBeforeInspection: true,
      permissions: const {
        Perm.stockDocApprove,
        Perm.productionFinishedInBeforeInspection,
      },
    );

    expect(find.text('路线：先入库后质检'), findsOneWidget);
    expect(find.byKey(_stockInSubmitKey), findsOneWidget);
    expect(find.byKey(_inspectSubmitKey), findsNothing);
    expect(find.widgetWithText(UtenButton, '先入库后质检'), findsOneWidget);
    expect(find.widgetWithText(UtenButton, '先质检后入库'), findsNothing);
    // 先入库后质检才显示「本次实收」列(默认=报工数量)。
    expect(_grid(tester).columns.map((column) => column.label), [
      '来源报工单',
      '货品名称',
      '编号',
      '颜色',
      '报工数量',
      '其中',
      '本次实收',
      '单位',
      '实称重量(kg)',
      '称重核对',
      '入库仓库',
      '库位号',
    ]);
    expect(tester.widget<TextField>(_qtyField(_itemA)).controller?.text, '10');

    // 实收与报工数量不一致：只弹顶部提示拦下，不出确认弹窗、不提交。
    await _toggleSelectAll(tester);
    await tester.enterText(_qtyField(_itemA), '8');
    await tester.pump();
    await _toggleSelectAll(tester);
    _pressSubmit(tester, key: _stockInSubmitKey);
    await tester.pump();
    expect(api.lastPostPath, isNull);
    expect(find.byType(InboundConfirmPoints), findsNothing);
    expect(
      _notices(tester).where((message) => message.contains('本次实收与报工数量不一致')),
      hasLength(1),
    );

    // 改回一致后提交：确认弹窗走先入库后质检口径。
    await _toggleSelectAll(tester);
    await tester.enterText(_qtyField(_itemA), '10');
    await tester.pump();
    await _toggleSelectAll(tester);
    _pressSubmit(tester, key: _stockInSubmitKey);
    await tester.pumpAndSettle();
    expect(find.text('先入库后质检(2 张报工单)'), findsOneWidget);
    expect(find.byType(InboundConfirmPoints), findsOneWidget);
    expect(find.text('确认登记送检'), findsNothing);
    await tester.tap(find.text('确认登记并先入库'));
    await tester.pumpAndSettle();

    final body = api.lastPostBody!;
    expect(body['stockInBeforeInspection'], isTrue);
    expect(body['idempotencyKey'] as String, endsWith(':prestock'));
    final lots = (body['lots'] as List).cast<Map<String, dynamic>>();
    expect(lots.map((lot) => lot['lotId']), [_itemA, _itemB]);
    for (final lot in lots) {
      expect(lot['countedQty'], 10);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('先入库后质检进页但无独立权限：退回先质检后入库路线', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _openBatchPage(
      tester,
      api: _BatchArrivalApi(),
      stockInBeforeInspection: true,
      // 默认权限只有 stock_doc:approve，没有「产成品先入库后质检」独立权限。
    );

    expect(find.text('路线：先质检后入库'), findsOneWidget);
    expect(find.text('路线：先入库后质检'), findsNothing);
    expect(find.byKey(_inspectSubmitKey), findsOneWidget);
    expect(find.byKey(_stockInSubmitKey), findsNothing);
    expect(
      _grid(tester).columns.map((column) => column.label),
      isNot(contains('本次实收')),
    );
    expect(tester.takeException(), isNull);
  });
}

/// 库位号格的输入框(共用列把 TextField 包在 WarehouseAutofillTextField 里)。
Finder _placeField(String reportItemId) => find.descendant(
  of: find.byKey(ValueKey('production-finished-arrival-place-$reportItemId')),
  matching: find.byType(TextField),
);

Finder _qtyField(String reportItemId) =>
    find.byKey(ValueKey('production-finished-arrival-qty-$reportItemId'));

Finder _warehouseCell(String reportItemId) =>
    find.byKey(ValueKey('production-finished-arrival-wh-$reportItemId'));

UtenInputDecoration _warehouseDecoration(
  WidgetTester tester,
  String reportItemId,
) =>
    tester
            .widget<InputDecorator>(
              find.descendant(
                of: _warehouseCell(reportItemId),
                matching: find.byType(InputDecorator),
              ),
            )
            .decoration
        as UtenInputDecoration;

UtenEditableGrid<dynamic> _grid(WidgetTester tester) =>
    tester.widget<UtenEditableGrid<dynamic>>(
      find.byKey(const Key('production-finished-arrival-grid')),
    );

Future<void> _toggleSelectAll(WidgetTester tester) async {
  await tester.tap(
    find.byWidgetPredicate((widget) => widget is Checkbox && widget.tristate),
  );
  await tester.pump();
}

/// 顶部通知队列里的文案(校验只弹顶部提示，不在页面内渲染错误文字)。
List<String> _notices(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(ProductionFinishedArrivalRegistrationPage)),
).read(appNotificationProvider).map((notice) => notice.message).toList();

void _pressSubmit(WidgetTester tester, {Key key = _inspectSubmitKey}) {
  tester.widget<UtenButton>(find.byKey(key)).onPressed!.call();
}

Future<ProviderContainer> _openBatchPage(
  WidgetTester tester, {
  required _BatchArrivalApi api,
  String? rememberedWarehouseId = 'warehouse-1',
  bool stockInBeforeInspection = false,
  Set<String> permissions = const {Perm.stockDocApprove},
  MemoryFormDraftStorage? drafts,
}) async {
  // 给了 [drafts] 就按真实应用打开本机草稿保护(登录身份 + 本机存储)。
  final draftOverrides = <Override>[
    if (drafts != null) ...[
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'warehouse-user'),
      ),
      formDraftStorageProvider.overrideWithValue(drafts),
    ],
  ];
  // 账号记忆「上次所选入库仓」(InboundFillScope.finished，偏好键
  // production.finishedArrivalFill)冷启动读本地缓存：键按 账号/服务器 作用域
  // 哈希(v2)，先用空 mock 走真实 apiBaseUrlProvider 链算出同款键再预置。
  SharedPreferences.setMockInitialValues({});
  final probePrefs = await SharedPreferences.getInstance();
  final probe = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(probePrefs),
      ...draftOverrides,
    ],
  );
  late final String scopedKey;
  try {
    scopedKey = scopedPagePreferenceCacheKey(
      'page_prefs_cache_production.finishedArrivalFill',
      probe.read(apiBaseUrlProvider),
      probe.read(authenticatedScopeProvider),
    );
  } finally {
    probe.dispose();
  }
  SharedPreferences.setMockInitialValues({
    if (rememberedWarehouseId != null)
      scopedKey: jsonEncode({'warehouseId': rememberedWarehouseId}),
  });
  final prefs = await SharedPreferences.getInstance();
  // 用 ProviderScope 挂在树上：测试结束卸载时一并释放 provider(含其定时器)。
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        ...draftOverrides,
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                key: const Key('open-batch-registration'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ProductionFinishedArrivalRegistrationPage(
                      reportIds: const [_reportA, _reportB],
                      canRegister: true,
                      // 任务中心多选时已选定路线(?preStock=1|0)。
                      route: stockInBeforeInspection
                          ? InboundRoute.stockInFirst
                          : InboundRoute.inspectFirst,
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
  return ProviderScope.containerOf(
    tester.element(find.byType(ProductionFinishedArrivalRegistrationPage)),
  );
}

class _BatchArrivalApi extends ApiClient {
  _BatchArrivalApi({
    this.twoItemsInFirstReport = false,
    this.goodsWarehouseDefaults = const {},
  }) : super(Dio());

  final bool twoItemsInFirstReport;
  final Map<String, String> goodsWarehouseDefaults;

  String? lastPostPath;
  Map<String, dynamic>? lastPostBody;
  final List<String> getPaths = [];
  final List<String> postPaths = [];

  /// 共用库位建议端点收到的请求体(按调用顺序)。
  final List<Map<String, dynamic>> suggestionBodies = [];

  List<String> get suggestionRequests => [
    for (final body in suggestionBodies) body['warehouseId'] as String,
  ];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/master/warehouses/dict') {
      return const [
        {'id': 'warehouse-1', 'name': '成品仓', 'selectableForNew': true},
        {'id': 'warehouse-2', 'name': '备用成品仓', 'selectableForNew': true},
      ];
    }
    if (path ==
        '/warehouse/production-finished-in/arrival-registrations/batch') {
      return [
        _reportJson(
          _reportA,
          'RB202608300001',
          twoItemsInFirstReport ? [_itemA, _itemA2] : [_itemA],
          _goodsA,
          'V51043',
          '三极插套',
        ),
        _reportJson(
          _reportB,
          'RB202608300002',
          [_itemB],
          _goodsB,
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
    getPaths.add(path);
    if (path.endsWith('/tasks/count')) {
      return const {'count': 2};
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
    postPaths.add(path);
    if (path == '/warehouse/place-suggestions') {
      final request = jsonDecode(jsonEncode(body)) as Map<String, dynamic>;
      suggestionBodies.add(request);
      final byGoods = _placeSuggestions[request['warehouseId']] ?? const {};
      return {
        'items': [
          for (final item
              in (request['items'] as List).cast<Map<String, dynamic>>())
            if (byGoods[item['goodsId']] case (final place, final source))
              {
                'goodsId': item['goodsId'],
                'colorId': item['colorId'],
                'place': place,
                'source': source,
              },
        ],
      };
    }
    if (path !=
        '/warehouse/production-finished-in/arrival-registrations/batch') {
      throw StateError('Unexpected POST $path');
    }
    lastPostPath = path;
    lastPostBody = Map<String, dynamic>.from(body! as Map);
    final lots = (lastPostBody!['lots'] as List).cast<Map<String, dynamic>>();
    final reportOf = {_itemA: _reportA, _itemA2: _reportA, _itemB: _reportB};
    final groups = <(String, String)>{
      for (final lot in lots)
        (reportOf[lot['lotId']]!, lot['warehouseId'] as String),
    };
    return {
      'registeredCount': groups.map((group) => group.$1).toSet().length,
      'reports': [
        for (final (report, warehouse) in groups)
          {
            'registrationId': report == _reportA
                ? '40000000-0000-0000-0000-000000000001'
                : '40000000-0000-0000-0000-000000000002',
            'reportId': report,
            'reportNo': report == _reportA
                ? 'RB202608300001'
                : 'RB202608300002',
            'warehouseId': warehouse,
            'warehouseName': '成品仓',
          },
      ],
      'sheets': const <Object>[],
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
    // 一行一批实物(批号沿用报工行号便于定位格子)；A 的首批是「需求 8 + 实际超产 2」。
    'lots': [
      for (var index = 0; index < itemIds.length; index++)
        {
          'lotId': itemIds[index],
          'members': [
            {'reportItemId': itemIds[index], 'qty': 10, 'kind': 'DEMAND'},
          ],
          if (itemIds[index] == _itemA) ...{
            'demandQty': 8,
            'actualSurplusQty': 2,
            'splitText': '需求 8 · 实际超产 2',
          },
          'lastWarehouseId': goodsWarehouseDefaults[itemIds[index]],
          'lineNo': 1,
          // 同报工多行时给不同货品：库位建议按「货品 × 颜色」回填，互不串行。
          'goodsId': index == 0 ? goodsId : _goodsA2,
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
