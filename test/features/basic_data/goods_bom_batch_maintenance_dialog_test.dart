import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_error.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/providers/goods_clipboard.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_batch_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/bom_component_picker.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_batch_maintenance_dialog.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import '../../support/audit_screenshot_support.dart';

const _capture = bool.fromEnvironment('UTEN_CAPTURE_UI');
const _captureKey = Key('bom-batch-capture');

class _Routes extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}

const _allPermissions = {
  Perm.goodsView,
  Perm.goodsBomEdit,
  Perm.goodsBomCreate,
  Perm.goodsBomDelete,
};
final _permissions = StateProvider<Set<String>>((ref) => _allPermissions);
const _normal = GoodsListItem(
  id: 'component-a',
  code: 'A01',
  name: '螺丝',
  unitName: '个',
  price: 2,
);
const _periodic = GoodsListItem(
  id: 'component-m',
  code: 'M01',
  name: '颗粒',
  unitName: '千克',
  issueMethod: GoodsIssueMethod.periodic,
  periodicCostBasis: GoodsPeriodicCostBasis.own,
);
const _copied = GoodsBomItem(
  id: 'old-edge',
  componentGoodsId: 'component-a',
  componentName: '螺丝',
  componentCode: 'A01',
  componentUnitName: '个',
  qty: 2,
  price: 3,
  total: 6,
  colorId: 'white',
  defaultSupplierId: 'supplier',
  summary: '保留来源设计值',
  controlStage: BomControlStage.finish,
  consumptionBasis: BomConsumptionBasis.perPackage,
  basisOutputQty: 10,
  allowPartialPackage: false,
);

class _Repository implements GoodsBomBatchRepository {
  final previews =
      <
        ({
          BomBatchAction action,
          List<String> targets,
          List<Map<String, dynamic>> items,
          List<String> components,
        })
      >[];
  final commits = <({String token, bool confirmed})>[];
  bool periodicConfirmation = false;
  bool loseCommitReceipt = false;
  bool commitConflict = false;
  ApiException? previewError;
  Completer<BomBatchPreview>? gate;
  @override
  Future<BomBatchPreview> preview({
    required BomBatchAction action,
    required List<String> targetGoodsIds,
    List<Map<String, dynamic>> items = const [],
    List<String> componentGoodsIds = const [],
  }) async {
    previews.add((
      action: action,
      targets: List.of(targetGoodsIds),
      items: [for (final body in items) Map.of(body)],
      components: List.of(componentGoodsIds),
    ));
    if (previewError != null) throw previewError!;
    if (gate != null) return gate!.future;
    if (periodicConfirmation && previews.length == 1) {
      throw ApiException(
        'VALIDATION_FAILED',
        '需要确认',
        fieldErrors: const [
          ApiFieldError(
            field: 'confirmSecondPeriodicMaterial',
            message: '产品 P1 要同时使用两种料',
          ),
        ],
      );
    }
    return response(action, targetGoodsIds);
  }

  BomBatchPreview response(BomBatchAction action, List<String> targets) {
    final componentCount = action == BomBatchAction.remove
        ? previews.last.components.length
        : previews.last.items.length;
    final overwrite = action == BomBatchAction.overwrite;
    return BomBatchPreview(
      previewToken: 'token-${previews.length}',
      action: action,
      selectedTargetCount: targets.length,
      changedTargetCount: 1,
      added: action == BomBatchAction.add ? 1 : 0,
      updated: overwrite ? componentCount : 0,
      removed: action == BomBatchAction.add ? 0 : 1,
      skipped: overwrite ? 0 : targets.length * componentCount - 1,
      targets: [
        for (final (index, target) in targets.indexed)
          BomBatchTarget(
            goodsId: target,
            goodsName: '货品 $target',
            goodsCode: target,
            added: index == 0 && action == BomBatchAction.add ? 1 : 0,
            updated: index == 0 && overwrite ? componentCount : 0,
            removed: index == 0 && action != BomBatchAction.add ? 1 : 0,
            skipped: overwrite ? 0 : componentCount - (index == 0 ? 1 : 0),
          ),
      ],
      affectedProducts: [
        const BomBatchAffectedProduct(
          goodsId: 'outside',
          goodsName: '共用总成',
          goodsCode: 'OUT',
          selected: false,
        ),
      ],
      otherUsageCount: 2,
      hiddenUsageCount: 1,
      warnings: const ['请核对重量差异'],
    );
  }

  @override
  Future<BomBatchResult> commit(
    String previewToken, {
    required bool confirmSharedChanges,
  }) async {
    commits.add((token: previewToken, confirmed: confirmSharedChanges));
    if (loseCommitReceipt && commits.length == 1) {
      throw NetworkTimeoutException();
    }
    if (commitConflict) {
      throw ApiException(
        'CONFLICT',
        '预览已过期',
        httpStatus: 409,
        hasResponseCode: true,
      );
    }
    return response(previews.last.action, previews.last.targets);
  }
}

class _Launcher extends StatelessWidget {
  const _Launcher(this.action, this.onDone, {this.initial = const []});
  final BomBatchAction action;
  final ValueChanged<BomBatchResult?> onDone;
  final List<GoodsBomItem> initial;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () async => onDone(
          await showGoodsBomBatchMaintenanceDialog(
            context: context,
            action: action,
            targetGoodsIds: action == BomBatchAction.overwrite
                ? ['P1']
                : ['P1', 'P2'],
            initialComponents: initial,
          ),
        ),
        child: const Text('打开维护'),
      ),
    ),
  );
}

Future<ProviderContainer> _open(
  WidgetTester tester,
  _Repository repository, {
  BomBatchAction action = BomBatchAction.add,
  List<GoodsListItem> picked = const [_normal],
  List<GoodsBomItem> initial = const [],
  List<GoodsBomItem> copied = const [],
  ValueChanged<BomBatchResult?>? onDone,
  Size size = const Size(1400, 900),
  double scale = 1,
  NavigatorObserver? observer,
  bool launch = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      authenticatedScopeProvider.overrideWithValue(
        const AuthenticatedScope(userId: 'operator'),
      ),
      isSuperAdminProvider.overrideWithValue(false),
      apiClientProvider.overrideWithValue(ApiClient(Dio())),
      goodsBomBatchRepositoryProvider.overrideWithValue(repository),
      bomComponentPickerProvider.overrideWithValue(
        (context, ref) async => picked,
      ),
      bomComponentRemovalPickerProvider.overrideWithValue(
        (context, ref) async => picked,
      ),
    ],
  );
  addTearDown(container.dispose);
  if (copied.isNotEmpty) {
    container.read(goodsClipboardProvider.notifier).copyBom(copied, '来源货品');
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: _captureKey,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: _capture
              ? auditScreenshotTheme(buildDarkTheme())
              : buildDarkTheme(),
          navigatorObservers: [?observer],
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: _Launcher(action, onDone ?? (_) {}, initial: initial),
        ),
      ),
    ),
  );
  if (launch) await tester.tap(find.text('打开维护'));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _pick(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('goods-bom-batch-pick')));
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('goods-bom-batch-submit')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'REMOVE supports 500 top-level cleanup identities and rejects 501 before preview',
    (tester) async {
      final repository = _Repository();
      final rows = List.generate(
        500,
        (index) => GoodsBomItem(
          id: 'row-$index',
          componentGoodsId: 'part-$index',
          qty: 1,
        ),
      );
      await _open(
        tester,
        repository,
        action: BomBatchAction.remove,
        initial: rows,
      );
      await _submit(tester);
      expect(repository.previews.single.components, hasLength(500));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await _open(
        tester,
        repository,
        action: BomBatchAction.remove,
        initial: [
          ...rows,
          const GoodsBomItem(
            id: 'row-501',
            componentGoodsId: 'part-501',
            qty: 1,
          ),
        ],
      );
      await _submit(tester);
      expect(repository.previews, hasLength(1));
      expect(find.textContaining('一次最多选择 500 个组件'), findsOneWidget);
    },
  );

  testWidgets(
    'late preview after revocation cannot reopen a closed maintenance dialog',
    (tester) async {
      final repository = _Repository()..gate = Completer<BomBatchPreview>();
      final container = await _open(tester, repository);
      await _pick(tester);
      await tester.tap(find.byKey(const Key('goods-bom-batch-submit')));
      await tester.pump();
      container.read(_permissions.notifier).state = {Perm.goodsView};
      await tester.pumpAndSettle();
      repository.gate!.complete(
        repository.response(BomBatchAction.add, ['P1', 'P2']),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('共用总成'), findsNothing);
      expect(repository.commits, isEmpty);
      expect(find.byKey(const Key('goods-bom-batch-dialog')), findsNothing);
    },
  );

  testWidgets(
    'a route pushed before its first builder cannot inherit old targets under a new boundary',
    (tester) async {
      final repository = _Repository();
      final routes = _Routes();
      final container = await _open(
        tester,
        repository,
        observer: routes,
        launch: false,
      );
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '打开维护'))
          .onPressed!();
      expect(
        routes.pushes,
        2,
        reason: 'dialog pushed synchronously, before builder frame',
      );
      container.read(_permissions.notifier).state = {Perm.goodsView};
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goods-bom-batch-dialog')), findsNothing);
      expect(repository.previews, isEmpty);
      expect(repository.commits, isEmpty);
    },
  );

  testWidgets(
    'ADD reviews exact targets, skips and shared influence before its separate commit',
    (tester) async {
      final repository = _Repository();
      BomBatchResult? done;
      await _open(tester, repository, onDone: (value) => done = value);
      await _pick(tester);
      await _submit(tester);
      expect(repository.previews.single.targets, ['P1', 'P2']);
      expect(repository.previews.single.items.single['qty'], 1);
      expect(repository.commits, isEmpty);
      expect(find.textContaining('跳过 1'), findsWidgets);
      expect(find.textContaining('共用总成'), findsOneWidget);
      expect(find.textContaining('受查看权限限制'), findsOneWidget);
      expect(find.text('请核对重量差异'), findsOneWidget);
      await _submit(tester);
      expect(repository.commits.single, (token: 'token-1', confirmed: true));
      expect(done, isNotNull);
    },
  );

  testWidgets(
    'changing quantity after preview discards the old token and requires a fresh review',
    (tester) async {
      final repository = _Repository();
      await _open(tester, repository);
      await _pick(tester);
      await _submit(tester);
      await tester.enterText(
        find.byKey(const ValueKey('goods-bom-batch-qty-component-a')),
        '2.5',
      );
      await tester.pumpAndSettle();
      expect(find.text('预览影响范围'), findsOneWidget);
      await _submit(tester);
      expect(repository.previews, hasLength(2));
      expect(repository.previews.last.items.single['qty'], 2.5);
      expect(repository.commits, isEmpty);
    },
  );

  testWidgets(
    'REMOVE submits only explicit component identities and has no quantity edit',
    (tester) async {
      final repository = _Repository();
      await _open(
        tester,
        repository,
        action: BomBatchAction.remove,
        picked: const [
          GoodsListItem(id: 'disabled-old', name: '停用旧件', status: '禁用'),
        ],
      );
      await _pick(tester);
      expect(find.byType(TextField), findsNothing);
      await _submit(tester);
      expect(repository.previews.single.action, BomBatchAction.remove);
      expect(repository.previews.single.components, ['disabled-old']);
      expect(repository.previews.single.items, isEmpty);
      expect(repository.commits, isEmpty);
    },
  );

  testWidgets(
    'copied rows whose doubles collide retain their own exact quantity in preview',
    (tester) async {
      final rows = [
        GoodsBomItem.fromJson({
          'id': 'edge-a',
          'componentGoodsId': 'component-a',
          'componentName': 'A',
          'qty': 1234567890123.1235,
          'qtyText': '1234567890123.12345',
        }),
        GoodsBomItem.fromJson({
          'id': 'edge-b',
          'componentGoodsId': 'component-b',
          'componentName': 'B',
          'qty': 1234567890123.1235,
          'qtyText': '1234567890123.12346',
        }),
      ];
      expect(rows.first.qty, rows.last.qty);
      final repository = _Repository();
      await _open(tester, repository, copied: rows);
      await tester.tap(find.text('使用已复制组件'));
      await tester.pumpAndSettle();
      await _submit(tester);
      expect(
        {
          for (final item in repository.previews.single.items)
            item['componentGoodsId']: item['qty'],
        },
        {
          'component-a': '1234567890123.12345',
          'component-b': '1234567890123.12346',
        },
      );
    },
  );

  testWidgets(
    'unchanged copied exact decimals reach preview without a double round trip',
    (tester) async {
      final copied = GoodsBomItem.fromJson({
        'id': 'exact-edge',
        'componentGoodsId': 'component-a',
        'componentName': '精确用量',
        'componentUnitName': '个',
        'qty': 1234567890123.1235,
        'qtyText': '1234567890123.12345',
        'price': 12345678901234.568,
        'priceText': '12345678901234.5678',
        'total': 12345678901234.988,
        'totalText': '12345678901234.9876',
        'basisOutputQty': 1234567890123.5432,
        'basisOutputQtyText': '1234567890123.54321',
      });
      final repository = _Repository();
      await _open(tester, repository, copied: [copied]);
      await tester.tap(find.text('使用已复制组件'));
      await tester.pumpAndSettle();
      final quantity = find.byKey(
        const ValueKey('goods-bom-batch-qty-component-a'),
      );
      expect(
        tester.widget<TextField>(quantity).controller!.text,
        '1234567890123.12345',
      );
      await _submit(tester);
      final unchanged = repository.previews.single.items.single;
      expect(unchanged['qty'], '1234567890123.12345');
      expect(unchanged['price'], '12345678901234.5678');
      expect(unchanged['total'], '12345678901234.9876');
      expect(unchanged['basisOutputQty'], '1234567890123.54321');
      await tester.enterText(quantity, '1234567890123.54321');
      await _submit(tester);
      final changed = repository.previews.last.items.single;
      expect(changed['qty'], '1234567890123.54321');
      expect(changed['price'], '12345678901234.5678');
      expect(changed.containsKey('total'), isFalse);
    },
  );

  testWidgets(
    'copied ADD preserves design metadata and recomputes copied total only when quantity changes',
    (tester) async {
      final repository = _Repository();
      await _open(tester, repository, copied: const [_copied]);
      await tester.tap(find.text('使用已复制组件'));
      await tester.pumpAndSettle();
      await _submit(tester);
      final body = repository.previews.single.items.single;
      expect(body, containsPair('qty', 2));
      expect(body, containsPair('total', 6));
      expect(body, containsPair('colorId', 'white'));
      expect(body, containsPair('defaultSupplierId', 'supplier'));
      expect(body, containsPair('controlStage', 'FINISH'));
      expect(body, containsPair('consumptionBasis', 'PER_PACKAGE'));
      expect(body, containsPair('basisOutputQty', 10));
      expect(body, containsPair('allowPartialPackage', false));
      await tester.enterText(
        find.byKey(const ValueKey('goods-bom-batch-qty-component-a')),
        '3',
      );
      await _submit(tester);
      expect(
        repository.previews.last.items.single.containsKey('total'),
        isFalse,
      );
    },
  );

  testWidgets(
    'single-product OVERWRITE is explicitly labelled and only previews its copied complete recipe',
    (tester) async {
      final repository = _Repository();
      await _open(
        tester,
        repository,
        action: BomBatchAction.overwrite,
        initial: const [_copied],
      );
      expect(find.text('覆盖整份组装清单'), findsOneWidget);
      expect(find.textContaining('嵌套共享子件自身的组装清单保持不变'), findsOneWidget);
      expect(find.byKey(const Key('goods-bom-batch-pick')), findsNothing);
      await _submit(tester);
      expect(repository.previews.single.action, BomBatchAction.overwrite);
      expect(repository.previews.single.targets, ['P1']);
      expect(repository.commits, isEmpty);
    },
  );

  testWidgets(
    'periodic quantities share gram conversion and server confirmations before preview completes',
    (tester) async {
      final repository = _Repository()..periodicConfirmation = true;
      await _open(tester, repository, picked: const [_periodic]);
      await _pick(tester);
      await tester.enterText(
        find.byKey(const ValueKey('goods-bom-batch-qty-component-m')),
        '12.5',
      );
      await _submit(tester);
      expect(find.text('保存前请确认'), findsOneWidget);
      expect(
        repository.previews.single.items.single,
        containsPair('qty', .0125),
      );
      expect(
        repository.previews.single.items.single,
        containsPair('unitWeightGrams', 12.5),
      );
      await tester.tap(find.byKey(const Key('periodic-bom-confirm')));
      await tester.pumpAndSettle();
      expect(
        repository.previews.last.items.single,
        containsPair('confirmSecondPeriodicMaterial', true),
      );
      expect(repository.commits, isEmpty);
    },
  );

  testWidgets(
    'lost commit receipt locks inputs and retries the exact same reviewed token',
    (tester) async {
      final repository = _Repository()..loseCommitReceipt = true;
      await _open(tester, repository);
      await _pick(tester);
      await _submit(tester);
      await _submit(tester);
      expect(find.text('重试本次提交'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('goods-bom-batch-qty-component-a')),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<UtenButton>(find.byKey(const Key('goods-bom-batch-pick')))
            .onPressed,
        isNull,
      );
      await _submit(tester);
      expect(repository.previews, hasLength(1));
      expect(repository.commits.map((call) => call.token).toList(), [
        'token-1',
        'token-1',
      ]);
    },
  );

  testWidgets(
    'definite conflict discards review and leaves component inputs available for a new preview',
    (tester) async {
      final repository = _Repository()..commitConflict = true;
      await _open(tester, repository);
      await _pick(tester);
      await _submit(tester);
      await _submit(tester);
      expect(find.text('预览已过期'), findsOneWidget);
      expect(find.text('预览影响范围'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('goods-bom-batch-qty-component-a')),
            )
            .enabled,
        isTrue,
      );
      await _submit(tester);
      expect(repository.previews, hasLength(2));
    },
  );

  testWidgets(
    'rejected batch shows individual target or line problems while preserving inputs',
    (tester) async {
      final repository = _Repository()
        ..previewError = ApiException(
          'VALIDATION_FAILED',
          '有多处问题',
          fieldErrors: List.generate(
            12,
            (index) =>
                ApiFieldError(field: '货品P$index', message: '第$index行组件会成环'),
          ),
        );
      await _open(tester, repository);
      await _pick(tester);
      await _submit(tester);
      expect(find.text('货品P0: 第0行组件会成环'), findsOneWidget);
      expect(find.textContaining('另有 2 项问题'), findsOneWidget);
      expect(find.text('货品P11: 第11行组件会成环'), findsNothing);
      expect(
        find.byKey(const ValueKey('goods-bom-batch-qty-component-a')),
        findsOneWidget,
      );
      expect(repository.commits, isEmpty);
    },
  );

  testWidgets(
    'revocation closes the dialog and old callbacks cannot preview or commit',
    (tester) async {
      final repository = _Repository();
      final container = await _open(tester, repository);
      await _pick(tester);
      final callback = tester
          .widget<UtenButton>(find.byKey(const Key('goods-bom-batch-submit')))
          .onPressed!;
      container.read(_permissions.notifier).state = {Perm.goodsView};
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goods-bom-batch-dialog')), findsNothing);
      callback();
      await tester.pumpAndSettle();
      expect(repository.previews, isEmpty);
      expect(repository.commits, isEmpty);
    },
  );

  testWidgets(
    'revocation between periodic confirmation push and its first builder leaves no sensitive child route',
    (tester) async {
      final repository = _Repository()..gate = Completer<BomBatchPreview>();
      final routes = _Routes();
      final container = await _open(
        tester,
        repository,
        picked: const [_periodic],
        observer: routes,
      );
      await _pick(tester);
      await tester.enterText(
        find.byKey(const ValueKey('goods-bom-batch-qty-component-m')),
        '12.5',
      );
      await tester.tap(find.byKey(const Key('goods-bom-batch-submit')));
      await tester.pump();
      repository.gate!.completeError(
        ApiException(
          'VALIDATION_FAILED',
          '需要确认',
          fieldErrors: const [
            ApiFieldError(
              field: 'confirmSecondPeriodicMaterial',
              message: '保密产品需要双料确认',
            ),
          ],
        ),
      );
      // Drain the response without a frame: showDialog has pushed, but its builder has not run.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(routes.pushes, 3);
      expect(find.text('保存前请确认'), findsNothing);
      container.read(_permissions.notifier).state = {Perm.goodsView};
      await tester.pumpAndSettle();
      expect(find.text('保密产品需要双料确认'), findsNothing);
      expect(find.text('保存前请确认'), findsNothing);
      expect(find.byKey(const Key('goods-bom-batch-dialog')), findsNothing);
      expect(repository.previews, hasLength(1));
      expect(repository.commits, isEmpty);
    },
  );

  for (final scenario in [
    (const Size(390, 844), 2.0),
    (const Size(844, 390), 1.5),
    (const Size(1440, 900), 1.0),
  ]) {
    testWidgets(
      'batch component maintenance reflows at ${scenario.$1} scale ${scenario.$2}',
      (tester) async {
        if (_capture) await loadAuditScreenshotFonts(tester);
        final repository = _Repository();
        await _open(
          tester,
          repository,
          size: scenario.$1,
          scale: scenario.$2,
          initial: const [_copied],
        );
        if (scenario.$1.width >= 1000) {
          await _submit(tester);
        } else {
          await tester.ensureVisible(
            find.byKey(const ValueKey('goods-bom-batch-qty-component-a')),
          );
          await tester.pumpAndSettle();
        }
        expect(find.byKey(const Key('goods-bom-batch-dialog')), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (_capture) {
          await expectLater(
            find.byKey(_captureKey),
            matchesGoldenFile(
              Directory.current.uri.resolve(
                'build/task-visual-checks/bom-batch-${scenario.$1.width.toInt()}x${scenario.$1.height.toInt()}.png',
              ),
            ),
          );
        }
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(repository.commits, isEmpty);
      },
    );
  }
}
