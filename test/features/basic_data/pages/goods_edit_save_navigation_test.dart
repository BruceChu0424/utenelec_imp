import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/color_node.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/mould_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/pages/goods_detail_page.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/mould_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/features/basic_data/widgets/mould_picker_field.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

import '../../../shared/drafts/memory_form_draft_storage.dart';
import '../../../support/goods_bom_edit_test_api.dart';

class _Goods extends Fake implements GoodsRepository {
  Map<String, dynamic>? body;
  bool reject = false;
  int reads = 0;
  VoidCallback? duringCreate;
  GoodsDetail value = GoodsDetail.fromJson({
    'id': 'g1',
    'name': '测试货品',
    'model': '货品自身型号',
    'cNumber': 'CUSTOMER-OLD',
    'categoryId': 'cat',
    'colorId': 'blue',
    'colorName': '蓝色',
    'unitId': 'piece',
    'sourceType': '采购',
    'status': '使用',
    'writable': true,
    'version': 4,
  });
  @override
  Future<GoodsDetail> detail(String id) async {
    reads++;
    return value;
  }

  @override
  Future<GoodsDetail> create(Map<String, dynamic> body) async {
    this.body = Map.of(body);
    duringCreate?.call();
    if (reject) throw ApiException('VALIDATION', '模拟保存失败', httpStatus: 422);
    return value;
  }

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    this.body = Map.of(body);
    if (reject) throw ApiException('CONFLICT', '模拟保存失败', httpStatus: 409);
    value = GoodsDetail.fromJson({
      ...body,
      'id': id,
      'writable': true,
      'version': (value.version ?? 0) + 1,
      'colorName': body['colorId'] == 'grey' ? '灰色' : '蓝色',
    });
  }
}

class _Bom extends Fake implements GoodsBomRepository {
  @override
  Future<List<GoodsBomItem>> list(String goodsId) async => const [];
}

class _Moulds extends Fake implements MouldRepository {
  final requests = <String>[];
  @override
  Future<MouldDetail> detail(String id) async {
    requests.add(id);
    return MouldDetail(id: id, code: 'RESTORED', name: '草稿关联模具');
  }
}

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot();
}

Finder _field(WidgetTester tester, String key) {
  final form = tester.state<MasterEditFormState>(find.byType(MasterEditForm));
  return find.byWidgetPredicate(
    (widget) =>
        widget is TextField &&
        widget.controller == form.controller.controllers[key],
  );
}

Future<({ProviderContainer container, GoRouter router})> _pump(
  WidgetTester tester,
  _Goods goods, {
  bool create = false,
  bool deepLink = false,
  _Moulds? moulds,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      sensitiveReadBoundaryProvider.overrideWith(
        (ref) => SensitiveReadBoundary(
          identity: ref.watch(authenticatedScopeProvider),
          api: ApiClient(Dio()),
          permissions: ref.watch(currentPermissionsProvider),
          superAdmin: false,
        ),
      ),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'goods-editor'),
      ),
      apiBaseUrlProvider.overrideWithValue('https://test.example/api'),
      formDraftStorageProvider.overrideWithValue(MemoryFormDraftStorage()),
      sessionSnapshotProvider.overrideWith(_Snapshots.new),
      currentPermissionsProvider.overrideWithValue({
        Perm.goodsView,
        Perm.materialCategoryView,
        Perm.goodsCreate,
        if (moulds != null) Perm.mouldView,
        Perm.goodsEdit,
        Perm.goodsStatus,
        Perm.goodsBomCreate,
        Perm.goodsBomEdit,
      }),
      isSuperAdminProvider.overrideWithValue(false),
      goodsRepositoryProvider.overrideWithValue(goods),
      if (moulds != null) mouldRepositoryProvider.overrideWithValue(moulds),
      goodsBomRepositoryProvider.overrideWithValue(_Bom()),
      apiClientProvider.overrideWithValue(GoodsBomEditTestApi(_Bom())),
      colorDictProvider.overrideWith(
        (ref) async => const [
          ColorListItem(id: 'blue', name: '蓝色'),
          ColorListItem(id: 'grey', name: '灰色'),
        ],
      ),
      unitDictProvider.overrideWith(
        (ref) async => const [UnitListItem(id: 'piece', name: '个')],
      ),
    ],
  );
  final path = create
      ? '/basicinfo/goods/new?categoryId=cat&returnTo=%2Fsource'
      : '/basicinfo/goods/g1?returnTo=%2Fsource';
  final router = GoRouter(
    initialLocation: deepLink ? path : '/source',
    routes: [
      DraftAwareGoRoute(
        path: '/source',
        builder: (context, _) => Scaffold(
          body: Column(
            children: [
              const Text('来源列表'),
              TextButton(
                onPressed: () => context.push(path),
                child: const Text('打开货品'),
              ),
              TextButton(
                onPressed: () => context.push('/basicinfo/goods/g1?tab=bom'),
                child: const Text('继续维护组装'),
              ),
            ],
          ),
        ),
      ),
      DraftAwareGoRoute(
        path: '/basicinfo/goods/new',
        builder: (_, _) => const GoodsDetailPage(categoryId: 'cat'),
      ),
      DraftAwareGoRoute(
        path: '/basicinfo/goods/:id',
        builder: (_, state) => GoodsDetailPage(
          goodsId: state.pathParameters['id'],
          initialTab: state.uri.queryParameters['tab'],
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (!deepLink) {
    await tester.tap(find.text('打开货品'));
    await tester.pumpAndSettle();
  }
  if (!create) {
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
  }
  return (container: container, router: router);
}

Future<void> _edit(WidgetTester tester, {bool create = false}) async {
  if (create) {
    await tester.enterText(_field(tester, 'name'), '新货品');
    final source = find.byWidgetPredicate(
      (widget) => widget is UtenDropdownField && widget.label == '来源',
    );
    await Scrollable.ensureVisible(tester.element(source), alignment: 0.5);
    await tester.tap(source);
    await tester.pumpAndSettle();
    await tester.tap(find.text('采购').last);
    await tester.pumpAndSettle();
    final unit = find.byWidgetPredicate(
      (widget) => widget is UtenDropdownField && widget.label == '基本单位',
    );
    await Scrollable.ensureVisible(tester.element(unit), alignment: 0.5);
    await tester.tap(unit);
    await tester.pumpAndSettle();
    await tester.tap(find.text('个').last);
    await tester.pumpAndSettle();
  }
  final customerModel = _field(tester, 'cNumber');
  await Scrollable.ensureVisible(tester.element(customerModel), alignment: 0.5);
  await tester.enterText(customerModel, 'CUSTOMER-NEW');
  final color = find.byWidgetPredicate(
    (widget) => widget is UtenDropdownField && widget.label == '颜色',
  );
  await Scrollable.ensureVisible(tester.element(color), alignment: 0.5);
  await tester.tap(color);
  await tester.pumpAndSettle();
  await tester.tap(find.text('灰色').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'new-goods draft restores the mould name for its exact UUID and submits that unchanged reference',
    (tester) async {
      final goods = _Goods();
      final moulds = _Moulds();
      await _pump(tester, goods, create: true, moulds: moulds);
      await _edit(tester, create: true);
      final draftHost =
          tester.state(find.byType(GoodsDetailBody))
              as FormDraftMixin<GoodsDetailBody>;
      final snapshot = draftHost.captureFormDraft();
      final form = Map<String, dynamic>.from(snapshot['form'] as Map);
      final customs = Map<String, dynamic>.from(form['custom'] as Map);
      customs['mouldId'] = 'restored-mould';
      form['custom'] = customs;
      snapshot['form'] = form;
      await draftHost.restoreFormDraft(snapshot);
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(MouldPickerField),
        matching: find.byType(TextField),
      );
      expect(
        tester.widget<TextField>(input).controller!.text,
        'RESTORED 草稿关联模具',
      );
      expect(moulds.requests, ['restored-mould']);
      final recovered = draftHost.captureFormDraft()['form'] as Map;
      expect((recovered['custom'] as Map)['mouldId'], 'restored-mould');
      await tester.tap(find.text('保存').hitTestable());
      await tester.pumpAndSettle();
      expect(goods.body?['mouldId'], 'restored-mould');
      expect(goods.body?['cNumber'], 'CUSTOMER-NEW');
      expect(goods.body?['colorId'], 'grey');
      expect(find.text('来源列表'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'create submits customer model/color UUID then clears local draft and returns to source',
    (tester) async {
      final goods = _Goods();
      final host = await _pump(tester, goods, create: true);
      var sawDraft = false;
      goods.duringCreate = () =>
          sawDraft = host.container.read(formDraftsProvider).isNotEmpty;
      await _edit(tester, create: true);
      await tester.tap(find.text('保存').hitTestable());
      await tester.pumpAndSettle();
      expect(
        goods.body,
        isNotNull,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((widget) => widget.data ?? widget.textSpan?.toPlainText())
            .join(' | '),
      );
      expect(goods.body?['cNumber'], 'CUSTOMER-NEW');
      expect(goods.body?['colorId'], 'grey');
      expect(sawDraft, isTrue);
      expect(host.container.read(formDraftsProvider), isEmpty);
      expect(find.text('来源列表'), findsOneWidget);
      expect(find.text('是否保存为草稿？'), findsNothing);
      await tester.tap(find.text('继续维护组装'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
      await enterBomEdit(tester);
      expect(find.byKey(const Key('goods-bom-add-component')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final deep in [false, true]) {
    testWidgets(
      'edit stays in the refreshed detail for undo, then explicit back uses ${deep ? 'returnTo' : 'push source'}',
      (tester) async {
        final goods = _Goods();
        final host = await _pump(tester, goods, deepLink: deep);
        expect(
          tester.widget<TextField>(_field(tester, 'cNumber')).controller!.text,
          'CUSTOMER-OLD',
        );
        await _edit(tester);
        await tester.tap(find.text('保存').hitTestable());
        await tester.pumpAndSettle();
        expect(goods.body?['cNumber'], 'CUSTOMER-NEW');
        expect(goods.body?['model'], '货品自身型号');
        expect(goods.body?['colorId'], 'grey');
        expect(goods.body?['version'], 4);
        expect(goods.reads, greaterThanOrEqualTo(2));
        expect(host.router.state.uri.path, '/basicinfo/goods/g1');
        expect(find.byType(MasterEditForm), findsNothing);
        expect(find.text('CUSTOMER-NEW'), findsOneWidget);
        expect(
          find.byKey(const Key('goods-detail-history-undo')),
          findsOneWidget,
        );
        expect(find.text('来源列表'), findsNothing);
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        expect(find.text('来源列表'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'rejected create retains customer model and color in the recoverable local draft',
    (tester) async {
      final goods = _Goods()..reject = true;
      final host = await _pump(tester, goods, create: true);
      await _edit(tester, create: true);
      await tester.tap(find.text('保存').hitTestable());
      await tester.pumpAndSettle();
      expect(host.router.state.uri.path, '/basicinfo/goods/new');
      expect(
        tester.widget<TextField>(_field(tester, 'cNumber')).controller!.text,
        'CUSTOMER-NEW',
      );
      final color = tester.widget<UtenDropdownField>(
        find.byWidgetPredicate(
          (widget) => widget is UtenDropdownField && widget.label == '颜色',
        ),
      );
      expect(color.value, 'grey');
      final draft = host.container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isFalse);
      final form = draft.data['form'] as Map;
      expect((form['text'] as Map)['cNumber'], 'CUSTOMER-NEW');
      expect((form['select'] as Map)['colorId'], 'grey');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed save retains customer model/color and the editable route',
    (tester) async {
      final goods = _Goods()..reject = true;
      final host = await _pump(tester, goods);
      await _edit(tester);
      await tester.tap(find.text('保存').hitTestable());
      await tester.pumpAndSettle();
      expect(host.router.state.uri.path, '/basicinfo/goods/g1');
      expect(
        tester.widget<TextField>(_field(tester, 'cNumber')).controller!.text,
        'CUSTOMER-NEW',
      );
      final color = tester.widget<UtenDropdownField>(
        find.byWidgetPredicate(
          (widget) => widget is UtenDropdownField && widget.label == '颜色',
        ),
      );
      expect(color.value, 'grey');
      expect(find.text('保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
