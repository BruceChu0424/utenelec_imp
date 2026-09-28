// ADR-134 goods English name on the goods detail page:
// - view mode shows the value and a "learned automatically" badge;
// - the name-only edit button follows the server capability canEditNameEn
//   (a salesperson without goods:edit can still fix the English name);
// - the dialog saves through the dedicated endpoint and reloads the detail;
// - the goods:edit full form carries nameEn so a full save never drops it.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_name_en_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

/// Raw code on purpose: pages never check it locally (the server hands out
/// GoodsDetail.canEditNameEn), so no Perm constant is needed in lib/.
const _goodsNameEnEdit = 'goods:name_en:edit';

void main() {
  testWidgets(
    'learned English name shows its badge and can be fixed without goods:edit',
    (tester) async {
      final goods = _GoodsRepository(
        _detail(
          nameEn: 'DOUBLE 3 PIN SOCKKET',
          source: 'LEARNED',
          canEditNameEn: true,
          version: 5,
        ),
      );
      final nameEn = _NameEnRepository();
      await _pump(
        tester,
        goods: goods,
        nameEn: nameEn,
        permissions: const {Perm.goodsView, _goodsNameEnEdit},
        canEdit: false,
      );

      expect(find.text('英文名称'), findsOneWidget);
      expect(find.text('DOUBLE 3 PIN SOCKKET'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('goods-name-en-learned')),
        findsOneWidget,
      );
      // No full edit for this user: the page-level 编辑 button is absent.
      expect(find.text('编辑'), findsNothing);

      // The server returns the corrected value on reload.
      goods.detailValue = _detail(
        nameEn: 'DOUBLE 3 PIN SOCKET',
        source: 'MANUAL',
        canEditNameEn: true,
        version: 6,
      );
      await tester.tap(find.byKey(const ValueKey('goods-name-en-edit')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('goods-name-en-dialog')),
        findsOneWidget,
      );
      expect(find.text('修改英文名称'), findsWidgets);

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('goods-name-en-input')),
          matching: find.byType(TextFormField),
        ),
        '  DOUBLE 3 PIN SOCKET  ',
      );
      await tester.tap(find.byKey(const ValueKey('goods-name-en-save')));
      await tester.pumpAndSettle();

      expect(nameEn.calls, [
        (id: 'goods-1', nameEn: 'DOUBLE 3 PIN SOCKET', version: 5),
      ]);
      expect(find.byKey(const ValueKey('goods-name-en-dialog')), findsNothing);
      expect(goods.detailCalls, 1);
      expect(find.text('DOUBLE 3 PIN SOCKET'), findsOneWidget);
      expect(find.byKey(const ValueKey('goods-name-en-learned')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('without the capability the English name is read-only', (
    tester,
  ) async {
    final goods = _GoodsRepository(
      _detail(nameEn: null, source: null, canEditNameEn: false),
    );
    await _pump(
      tester,
      goods: goods,
      nameEn: _NameEnRepository(),
      // Even a local permission code does not show the button: the server
      // capability decides (object scope may be read-only).
      permissions: const {Perm.goodsView, _goodsNameEnEdit},
      canEdit: false,
    );

    final tile = find.byKey(const ValueKey('goods-name-en-view'));
    expect(tile, findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text('—')), findsOneWidget);
    expect(find.byKey(const ValueKey('goods-name-en-edit')), findsNothing);
  });

  testWidgets('unchanged or cancelled dialog sends nothing', (tester) async {
    final goods = _GoodsRepository(
      _detail(nameEn: 'SOCKET', source: 'MANUAL', canEditNameEn: true),
    );
    final nameEn = _NameEnRepository();
    await _pump(
      tester,
      goods: goods,
      nameEn: nameEn,
      permissions: const {Perm.goodsView},
      canEdit: false,
    );

    await tester.tap(find.byKey(const ValueKey('goods-name-en-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('goods-name-en-input')),
        matching: find.byType(TextFormField),
      ),
      ' SOCKET ',
    );
    await tester.tap(find.byKey(const ValueKey('goods-name-en-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('goods-name-en-dialog')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('goods-name-en-edit')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(nameEn.calls, isEmpty);
    expect(goods.detailCalls, 0);
  });

  testWidgets('a stale version closes the dialog and reloads the detail', (
    tester,
  ) async {
    final goods = _GoodsRepository(
      _detail(nameEn: 'SOCKET', source: 'MANUAL', canEditNameEn: true),
    );
    final nameEn = _NameEnRepository(
      failure: ApiException('CONFLICT', '货品已被他人修改, 请刷新后再试', httpStatus: 409),
    );
    await _pump(
      tester,
      goods: goods,
      nameEn: nameEn,
      permissions: const {Perm.goodsView},
      canEdit: false,
    );

    await tester.tap(find.byKey(const ValueKey('goods-name-en-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('goods-name-en-input')),
        matching: find.byType(TextFormField),
      ),
      'WALL SOCKET',
    );
    await tester.tap(find.byKey(const ValueKey('goods-name-en-save')));
    await tester.pumpAndSettle();

    expect(nameEn.calls, hasLength(1));
    expect(find.byKey(const ValueKey('goods-name-en-dialog')), findsNothing);
    expect(goods.detailCalls, 1);
  });

  testWidgets('the dialog cannot be closed while the save is running', (
    tester,
  ) async {
    final goods = _GoodsRepository(
      _detail(nameEn: 'SOCKET', source: 'LEARNED', canEditNameEn: true),
    );
    final gate = Completer<void>();
    final nameEn = _NameEnRepository(gate: gate);
    await _pump(
      tester,
      goods: goods,
      nameEn: nameEn,
      permissions: const {Perm.goodsView},
      canEdit: false,
    );

    await tester.tap(find.byKey(const ValueKey('goods-name-en-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('goods-name-en-input')),
        matching: find.byType(TextFormField),
      ),
      'WALL SOCKET',
    );
    await tester.tap(find.byKey(const ValueKey('goods-name-en-save')));
    await tester.pump();
    expect(nameEn.calls, hasLength(1));

    final dialog = find.byKey(const ValueKey('goods-name-en-dialog'));
    // Cancel is disabled, the barrier and the back key do nothing.
    await tester.tap(
      find.byKey(const ValueKey('goods-name-en-cancel')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(dialog, findsOneWidget);
    await tester.tapAt(const Offset(8, 8));
    await tester.pump();
    expect(dialog, findsOneWidget);
    await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
    await tester.pump();
    expect(dialog, findsOneWidget);

    // The server answers: the dialog closes and the page reloads the detail
    // so the next save carries the new version.
    goods.detailValue = _detail(
      nameEn: 'WALL SOCKET',
      source: 'MANUAL',
      canEditNameEn: true,
      version: 2,
    );
    gate.complete();
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(goods.detailCalls, 1);
    expect(find.text('WALL SOCKET'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('goods:edit full form carries nameEn in the save body', (
    tester,
  ) async {
    final goods = _GoodsRepository(
      _detail(nameEn: 'SOCKET', source: 'LEARNED', canEditNameEn: true),
    );
    await _pump(
      tester,
      goods: goods,
      nameEn: _NameEnRepository(),
      permissions: const {Perm.goodsView, Perm.goodsEdit},
      canEdit: true,
    );

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    // The form label is a rich widget (required marker support), so find the
    // text first and walk up to its TextField.
    final field = find.ancestor(
      of: find.text('英文名称', findRichText: true),
      matching: find.byType(TextField),
    );
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).controller?.text, 'SOCKET');

    await tester.enterText(field, 'WALL SOCKET 2 GANG');
    await tester.tap(find.text('保存').hitTestable());
    await tester.pumpAndSettle();

    expect(goods.updateBody?['nameEn'], 'WALL SOCKET 2 GANG');
    expect(goods.updateBody?['name'], '两开多功能三极插座');
    expect(tester.takeException(), isNull);
  });
}

GoodsDetail _detail({
  required String? nameEn,
  required String? source,
  required bool canEditNameEn,
  int version = 1,
}) => GoodsDetail.fromJson({
  'id': 'goods-1',
  'code': '280235165',
  'name': '两开多功能三极插座',
  'nameEn': nameEn,
  'nameEnSource': source,
  'canEditNameEn': canEditNameEn,
  'categoryId': 'category-1',
  'sourceType': '自制',
  'status': '使用',
  'writable': true,
  'unitId': 'unit-piece',
  'unitName': '个',
  'version': version,
});

Future<void> _pump(
  WidgetTester tester, {
  required _GoodsRepository goods,
  required _NameEnRepository nameEn,
  required Set<String> permissions,
  required bool canEdit,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        goodsRepositoryProvider.overrideWithValue(goods),
        goodsNameEnRepositoryProvider.overrideWithValue(nameEn),
        colorDictProvider.overrideWith((ref) async => const []),
        unitDictProvider.overrideWith(
          (ref) async => const [UnitListItem(id: 'unit-piece', name: '个')],
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: GoodsDetailBody(
            initialDetail: goods.detailValue,
            initialCategoryId: 'category-1',
            initialTab: 0,
            canCreate: false,
            canEdit: canEdit,
            canStatus: false,
            canBomCreate: false,
            canBomEdit: false,
            canBomDelete: false,
            onToggleStatus: null,
            onDelete: null,
            onViewMovements: null,
            onDataChanged: null,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _GoodsRepository implements GoodsRepository {
  _GoodsRepository(this.detailValue);

  GoodsDetail detailValue;
  int detailCalls = 0;
  Map<String, dynamic>? updateBody;

  @override
  Future<GoodsDetail> detail(String id) async {
    detailCalls++;
    return detailValue;
  }

  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    updateBody = body;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NameEnRepository implements GoodsNameEnRepository {
  _NameEnRepository({this.failure, this.gate});

  final ApiException? failure;

  /// When set, update() waits for it so a test can act mid-request.
  final Completer<void>? gate;
  final calls = <({String id, String? nameEn, int? version})>[];

  @override
  Future<void> update(
    String goodsId, {
    required String? nameEn,
    required int? version,
  }) async {
    calls.add((
      id: goodsId,
      nameEn: normalizeGoodsNameEnInput(nameEn),
      version: version,
    ));
    if (gate != null) await gate!.future;
    if (failure != null) throw failure!;
  }
}
