import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/delivery/order_delivery_plan.dart';
import 'package:uten_imp/shared/delivery/order_delivery_repository.dart';
import 'package:uten_imp/shared/delivery/order_delivery_window.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

class _Repository extends OrderDeliveryRepository {
  _Repository() : super(ApiClient(Dio()));
  int reads = 0, previews = 0, frozenReads = 0;
  final frozenScopes = <List<String>>[];
  Completer<Map<String, dynamic>>? pending;
  @override
  Future<OrderDeliveryBom> frozenBom({
    required String orderId,
    required String itemId,
    String context = 'SALES',
  }) async {
    frozenReads++;
    frozenScopes.add([orderId, itemId, context]);
    return OrderDeliveryBom.fromJson({
      'missing': true,
      'root': null,
      'missingReason': '旧单未冻结BOM，不能用当前BOM替代',
      'deliveryPlan': OrderDeliveryPlan.assembled().toJson(),
    });
  }

  @override
  Future<OrderDeliveryBom> bom(String goodsId) async {
    reads++;
    return OrderDeliveryBom.fromJson({
      'bomFingerprint': 'authoritative-v1',
      'root': {
        'path': <String>[],
        'goodsId': goodsId,
        'name': '原产品',
        'childrenState': 'LOADED',
        'children': [
          {
            'path': ['module'],
            'goodsId': 'module-goods',
            'code': 'M',
            'name': '模块',
            'qtyExact': '2',
            'childrenState': 'LOADED',
            'children': [
              {
                'path': ['module', 'part'],
                'goodsId': 'part-goods',
                'code': 'P',
                'name': '激光底板',
                'qtyExact': '3',
                'childrenState': 'NONE',
                'requiredOperations': ['LASER'],
                'children': <Map<String, dynamic>>[],
              },
              {
                'path': ['module', 'inner'],
                'goodsId': 'inner-goods',
                'code': 'I',
                'name': '内部功能组件',
                'qtyExact': '1',
                'childrenState': 'LOADED',
                'children': [
                  {
                    'path': ['module', 'inner', 'leaf'],
                    'goodsId': 'inner-leaf-goods',
                    'code': 'L',
                    'name': '内部激光片',
                    'qtyExact': '1',
                    'childrenState': 'NONE',
                    'requiredOperations': ['LASER'],
                    'children': <Map<String, dynamic>>[],
                  },
                ],
              },
            ],
          },
          {
            'path': ['fixed'],
            'goodsId': 'fixed-goods',
            'name': '必装组件',
            'qtyExact': '1',
            'childrenState': 'MISSING',
            'mandatoryAssembly': true,
            'children': <Map<String, dynamic>>[],
          },
        ],
      },
    });
  }

  @override
  Future<Map<String, dynamic>> preview({
    required String goodsId,
    required String quantity,
    required OrderDeliveryPlan plan,
    String? unitId,
    String? unitRate,
  }) {
    previews++;
    return pending?.future ??
        Future.value({
          'deliveryPlan': plan.toJson(),
          'issues': <Map<String, dynamic>>[],
        });
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Repository repository, {
  ValueChanged<OrderDeliveryPlan>? changed,
  bool readOnly = false,
  bool includeSavedIdentity = true,
  String readContext = 'SALES',
}) async {
  await tester.binding.setSurfaceSize(const Size(1250, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        orderDeliveryRepositoryProvider.overrideWithValue(repository),
        sensitiveReadBoundaryProvider.overrideWithValue(
          SensitiveReadBoundary(
            identity: null,
            api: repository.api,
            permissions: const {},
            superAdmin: false,
          ),
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('zh')],
        home: Scaffold(
          body: OrderDeliveryPlanCell(
            plan: OrderDeliveryPlan.assembled().copyWith(mode: 'BOM'),
            goodsId: 'goods',
            goodsName: '原产品',
            quantity: '100',
            readOnly: readOnly,
            orderId: readOnly && includeSavedIdentity ? 'saved-order' : null,
            orderItemId: readOnly && includeSavedIdentity ? 'saved-item' : null,
            readContext: readContext,
            onChanged: changed,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'header search finds a folded grandchild and clearing restores folds and delivery choices',
    (tester) async {
      final repository = _Repository();
      var changes = 0;
      await _pump(tester, repository, changed: (_) => changes++);
      await tester.tap(find.text('按BOM层级交付'));
      await tester.pumpAndSettle();
      final moduleChoice = find.byKey(const ValueKey('delivery-split-module'));
      final internalChoice = find.byKey(
        const ValueKey('delivery-split-module/inner'),
      );
      expect(tester.widget<Checkbox>(internalChoice).onChanged, isNull);
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('delivery-laser-module/inner/leaf')),
            )
            .value,
        isTrue,
      );
      await tester.tap(moduleChoice);
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(moduleChoice).value, isTrue);
      expect(tester.widget<Checkbox>(internalChoice).onChanged, isNotNull);
      await tester.tap(find.text('全部收起'));
      await tester.pumpAndSettle();
      expect(find.text('激光底板'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('master-column-filter-code')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'P');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(find.text('原产品'), findsWidgets);
      expect(find.text('模块'), findsWidgets);
      expect(find.text('激光底板'), findsWidgets);
      expect(find.text('内部功能组件'), findsNothing);
      expect(tester.widget<Checkbox>(moduleChoice).value, isTrue);
      await tester.tap(find.byKey(const ValueKey('master-column-filter-code')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('所有'));
      await tester.pumpAndSettle();
      expect(find.text('模块'), findsNothing);
      expect(find.text('激光底板'), findsNothing);
      await tester.tap(find.text('全部展开'));
      await tester.pumpAndSettle();
      expect(find.text('内部激光片'), findsWidgets);
      expect(tester.widget<Checkbox>(moduleChoice).value, isTrue);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(changes, 0);
      expect(repository.previews, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'read-only order scope uses frozen data and preserves missing history',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository, readOnly: true);
      await tester.tap(find.text('按BOM层级交付'));
      await tester.pumpAndSettle();
      expect(repository.frozenReads, 1);
      expect(repository.frozenScopes, [
        ['saved-order', 'saved-item', 'SALES'],
      ]);
      expect(repository.reads, 0);
      expect(find.textContaining('旧单未冻结BOM'), findsWidgets);
      expect(find.text('激光底板'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    },
  );

  for (final context in ['MANAGER', 'FINANCE']) {
    testWidgets('read-only $context retains its scoped frozen endpoint', (
      tester,
    ) async {
      final repository = _Repository();
      await _pump(tester, repository, readOnly: true, readContext: context);
      await tester.tap(find.text('按BOM层级交付'));
      await tester.pumpAndSettle();
      expect(repository.frozenScopes, [
        ['saved-order', 'saved-item', context],
      ]);
      expect(repository.reads, 0);
      expect(repository.previews, 0);
      expect(find.text('确认'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
    'read-only missing line identity never loads generic current BOM',
    (tester) async {
      final repository = _Repository();
      await _pump(
        tester,
        repository,
        readOnly: true,
        includeSavedIdentity: false,
      );
      await tester.tap(find.text('按BOM层级交付'));
      await tester.pumpAndSettle();
      expect(repository.reads, 0);
      expect(repository.frozenReads, 0);
      expect(repository.previews, 0);
      expect(find.text('激光底板'), findsNothing);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'one movable floating window retains full structure and authoritative constraints',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await tester.tap(find.text('按BOM层级交付'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenFloatingWindow), findsOneWidget);
      expect(repository.reads, 1);
      expect(find.text('激光底板'), findsWidgets);
      expect(find.text('随上层整件'), findsWidgets);
      expect(find.text('此组件必须保持组装'), findsWidgets);
      final laser = tester.widget<Checkbox>(
        find.byKey(const ValueKey('delivery-laser-module/part')),
      );
      expect(laser.value, isTrue);
      expect(laser.onChanged, isNull);
      expect(find.byKey(const ValueKey('delivery-split-fixed')), findsNothing);
      final window = tester.state<UtenFloatingWindowState>(
        find.byType(UtenFloatingWindow),
      );
      final before = window.bounds;
      await tester.drag(find.text('设置交付方式'), const Offset(50, 25));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(window.bounds.left, greaterThan(before.left));
      expect(window.bounds.left, lessThanOrEqualTo(before.left + 50));
      expect(window.bounds.top, greaterThan(before.top));
      expect(window.bounds.top, lessThanOrEqualTo(before.top + 25));
      final moved = window.bounds;
      final resize = await tester.startGesture(
        Offset(moved.right - 2, moved.bottom - 2),
      );
      await resize.moveBy(const Offset(80, 50));
      await resize.up();
      await tester.pumpAndSettle();
      expect(window.bounds.left, moved.left);
      expect(window.bounds.width, greaterThan(moved.width));
      expect(window.bounds.right, lessThanOrEqualTo(1250 - 8));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(UtenFloatingWindow), findsNothing);
    },
  );

  testWidgets(
    'rapid confirm posts once and retains draft on preview rejection',
    (tester) async {
      final repository = _Repository()
        ..pending = Completer<Map<String, dynamic>>();
      var changes = 0;
      await _pump(tester, repository, changed: (_) => changes++);
      await tester.tap(find.text('按BOM层级交付'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pump();
      await tester.tap(find.text('确认'), warnIfMissed: false);
      await tester.pump();
      expect(repository.previews, 1);
      repository.pending!.complete({
        'issues': [
          {'message': 'BOM版本已变化'},
        ],
      });
      await tester.pumpAndSettle();
      expect(changes, 0);
      expect(find.byType(UtenFloatingWindow), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );
}
