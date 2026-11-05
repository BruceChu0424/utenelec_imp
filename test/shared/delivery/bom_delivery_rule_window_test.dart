import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/delivery/bom_delivery_rule_window.dart';
import 'package:uten_imp/shared/delivery/order_delivery_repository.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

OrderDeliveryBom snapshot({
  bool mandatory = false,
  String fingerprint = 'v1',
}) => OrderDeliveryBom.fromJson({
  'bomFingerprint': fingerprint,
  'root': {
    'path': <String>[],
    'goodsId': 'root',
    'name': '产品',
    'childrenState': 'LOADED',
    'children': [
      {
        'path': ['edge'],
        'goodsId': 'part',
        'name': '组件',
        'childrenState': 'NONE',
        'mandatoryAssembly': mandatory,
        'materialRole': 'PART',
        'requiredOperations': <String>[],
        'children': <Map<String, dynamic>>[],
      },
    ],
  },
});

class _Repository extends OrderDeliveryRepository {
  _Repository() : super(ApiClient(Dio()));
  int reads = 0;
  final writes = <Map<String, dynamic>>[];
  bool uncertain = false;
  OrderDeliveryBom current = snapshot();
  @override
  Future<OrderDeliveryBom> bom(String goodsId) async {
    reads++;
    return current;
  }

  @override
  Future<OrderDeliveryBom> updateRule(
    String edgeId,
    Map<String, dynamic> body,
  ) async {
    writes.add(Map<String, dynamic>.from(body));
    if (uncertain) throw TimeoutException('unknown outcome');
    current = snapshot(
      mandatory: body['mandatoryAssembly'] == true,
      fingerprint: 'v2',
    );
    return current;
  }
}

Future<void> _pumpRule(
  WidgetTester tester,
  _Repository repository,
  ValueChanged<bool> finished,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        orderDeliveryRepositoryProvider.overrideWithValue(repository),
        currentPermissionsProvider.overrideWithValue(const {Perm.goodsBomEdit}),
        isSuperAdminProvider.overrideWithValue(false),
        sensitiveReadBoundaryProvider.overrideWithValue(
          SensitiveReadBoundary(
            identity: null,
            api: repository.api,
            permissions: const {Perm.goodsBomEdit},
            superAdmin: false,
          ),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => finished(
                await showBomDeliveryRuleWindow(
                  context,
                  rootGoodsId: 'root',
                  edgeId: 'edge',
                  componentName: '组件',
                  isCurrent: () => true,
                ),
              ),
              child: const Text('打开规则'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开规则'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'master delivery rules save the selected edge with the reviewed root fingerprint',
    (tester) async {
      final repository = _Repository();
      bool? finished;
      await _pumpRule(tester, repository, (value) => finished = value);
      await tester.tap(find.text('必须保持组装'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(repository.writes, hasLength(1));
      expect(repository.writes.single, {
        'rootGoodsId': 'root',
        'bomFingerprint': 'v1',
        'mandatoryAssembly': true,
        'materialRole': 'PART',
        'requiredOperations': <String>[],
      });
      expect(finished, isTrue);
    },
  );
  testWidgets(
    'unknown rule save reads current rules before permitting an explicit fresh review',
    (tester) async {
      final repository = _Repository()..uncertain = true;
      await _pumpRule(tester, repository, (_) {});
      await tester.tap(find.text('必须保持组装'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('核对原保存结果'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
      await tester.tap(find.text('核对原保存结果'));
      await tester.pumpAndSettle();
      expect(repository.reads, 2);
      expect(repository.writes, hasLength(1));
      expect(find.text('重新载入核对'), findsOneWidget);
      expect(find.text('保存'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
    },
  );
}
