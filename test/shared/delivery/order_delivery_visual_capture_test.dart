import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/feedback/uten_floating_window.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_delivery_components_table.dart';
import 'package:uten_imp/features/warehouse/widgets/warehouse_sales_picking_fields.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/delivery/bom_delivery_rule_window.dart';
import 'package:uten_imp/shared/delivery/order_delivery_plan.dart';
import 'package:uten_imp/shared/delivery/order_delivery_repository.dart';
import 'package:uten_imp/shared/delivery/order_delivery_window.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';
import '../../support/dialog_fixture_capture.dart';

const _output = 'output/order-bom-delivery-20261104-frontend';
Map<String, dynamic> _node(
  String id,
  String name,
  List<String> path, {
  bool mandatory = false,
  bool laser = false,
  List<Map<String, dynamic>> children = const [],
}) => {
  'path': path,
  'goodsId': id,
  'code': id,
  'name': name,
  'unitName': '个',
  'qtyExact': '2',
  'consumptionBasis': 'PER_UNIT',
  'materialRole': 'PART',
  'mandatoryAssembly': mandatory,
  'requiredOperations': [if (laser) 'LASER'],
  'childrenState': children.isEmpty ? 'NONE' : 'LOADED',
  'children': children,
};

class _Repository extends OrderDeliveryRepository {
  _Repository() : super(ApiClient(Dio()));
  @override
  Future<OrderDeliveryBom> bom(String goodsId) async =>
      OrderDeliveryBom.fromJson({
        'bomFingerprint': 'synthetic-fixture-v1',
        'root': _node(
          'DEMO-PRODUCT',
          '合成多层组合产品',
          <String>[],
          children: [
            _node(
              'DEMO-MOD-A',
              '合成开关模块A',
              ['module-a'],
              children: [
                _node(
                  'DEMO-SUB-A',
                  '合成二级功能组件',
                  ['module-a', 'sub-a'],
                  children: [
                    _node('DEMO-PLATE', '合成激光底板', [
                      'module-a',
                      'sub-a',
                      'plate',
                    ], laser: true),
                    _node('DEMO-BOLT', '合成固定螺丝', ['module-a', 'sub-a', 'bolt']),
                  ],
                ),
              ],
            ),
            _node(
              'DEMO-FIXED',
              '合成必装激光组件',
              ['fixed'],
              mandatory: true,
              laser: true,
              children: [
                _node('DEMO-CONTACT', '合成组件内触点', ['fixed', 'contact']),
              ],
            ),
            _node('DEMO-MANUAL', '合成随货说明书', ['manual']),
          ],
        ),
      });
}

Future<void> _mount(
  WidgetTester tester,
  _Repository repository,
  Widget body,
  String title, {
  Size size = const Size(1600, 1000),
}) async {
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        orderDeliveryRepositoryProvider.overrideWithValue(repository),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.goodsBomEdit,
          Perm.warehouseSalesOutboundView,
          Perm.warehouseSalesOutboundExecute,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        sensitiveReadBoundaryProvider.overrideWithValue(
          SensitiveReadBoundary(
            identity: null,
            api: repository.api,
            permissions: const {
              Perm.goodsBomEdit,
              Perm.warehouseSalesOutboundExecute,
            },
            superAdmin: false,
          ),
        ),
      ],
      child: dialogFixtureBoundary(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh')],
          home: Scaffold(
            appBar: UtenAppBar(title: title),
            body: Padding(padding: const EdgeInsets.all(24), child: body),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'capture real delivery, warehouse, and rule widgets with synthetic data',
    (tester) async {
      if (!dialogFixtureCaptureEnabled) return;
      await loadDialogFixtureFonts();
      final repository = _Repository();
      await _mount(
        tester,
        repository,
        OrderDeliveryPlanCell(
          plan: OrderDeliveryPlan.assembled().copyWith(
            mode: 'BOM',
            packaging: 'BULK',
            nodeModes: [
              {
                'path': ['module-a'],
                'mode': 'CHILDREN',
              },
            ],
          ),
          goodsId: 'DEMO-PRODUCT',
          goodsName: '合成多层组合产品',
          quantity: '100',
          readOnly: false,
        ),
        '销售订货单 / 合成视觉验证数据',
        size: const Size(1600, 1100),
      );
      await tester.tap(find.text('按BOM层级交付'));
      await tester.pumpAndSettle();
      await tester.drag(find.text('设置交付方式'), const Offset(-90, -150));
      await tester.pumpAndSettle();
      final window = tester.state<UtenFloatingWindowState>(
        find.byType(UtenFloatingWindow),
      );
      final rect = window.bounds;
      final resize = await tester.startGesture(
        Offset(rect.right - 2, rect.bottom - 2),
      );
      await resize.moveBy(const Offset(250, 240));
      await resize.up();
      await tester.pumpAndSettle();
      expect(find.byType(UtenFloatingWindow), findsOneWidget);
      final codeHeader = find
          .descendant(
            of: find.byType(UtenFloatingWindow),
            matching: find.text('编号'),
          )
          .first;
      await tester.tap(codeHeader);
      await tester.pumpAndSettle();
      await captureDialogFixture(
        tester,
        '01-sales-delivery-tree-resized-filter',
        outputDirectory: _output,
      );
      await tester.tapAt(const Offset(20, 900));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      final detail = WarehouseSalesOutboundDetail.fromJson({
        'id': 'DEMO-SHIPMENT',
        'billNo': '合成出货单-DEMO',
        'warehouseWorkStatus': 'PENDING_PICK',
        'allowedWarehouseTargets': ['SHIPPED'],
        'lines': [
          {'id': 'DEMO-PARENT', 'goodsId': 'DEMO-PRODUCT', 'quantity': '100'},
        ],
        'deliveryComponents': [
          for (var i = 0; i < 3; i++)
            {
              'id': 'DEMO-COMP-$i',
              'shipmentItemId': 'DEMO-PARENT',
              'goodsId': 'DEMO-PART-$i',
              'goodsCode': 'DEMO-PART-$i',
              'goodsName': ['合成激光底板', '合成已加工后座', '合成待加工支架'][i],
              'unitName': '个',
              'quantityExact': '${(i + 1) * 100}',
              'originalQuantityExact': '${(i + 1) * 100}',
              'processedQty': i == 1 ? '200' : '0',
              'revision': 1,
              'path': ['DEMO-EDGE-$i'],
              'operations': ['LASER'],
              'processingTargets': [
                {
                  'path': ['DEMO-EDGE-$i', 'DEMO-INTERNAL-PLATE'],
                  'goodsId': 'DEMO-TARGET-$i',
                  'code': 'DEMO-TARGET-$i',
                  'name': ['合成内部激光面板', '合成内部标识底板', '合成内部刻字片'][i],
                  'unitName': '片',
                  'quantityExact': '${(i + 1) * 200}',
                  'quantityNumerator': '${(i + 1) * 200}',
                  'quantityDenominator': '1',
                  'operations': ['LASER'],
                },
              ],
              'processingWorkshopId': 'DEMO-WORKSHOP',
              'processingIssuedAt': i == 0 ? null : '2026-11-04T10:00:00Z',
              'processingReceivedAt': null,
              'warehouseId': 'DEMO-WH',
              'stockPlace': 'DEMO-A-${i + 1}',
              'warehouseChoices': [
                {
                  'warehouseId': 'DEMO-WH',
                  'warehouseName': '合成原料仓',
                  'availableQty': '1000',
                  'requiresSourceCheck': true,
                },
              ],
            },
        ],
      });
      final draft = WarehouseSalesPickingDraft(detail);
      await _mount(
        tester,
        repository,
        WarehouseDeliveryComponentsTabs(
          commercial: const Center(child: Text('合成订单产品100个')),
          details: [detail],
          draftOf: (_) => draft,
          onChanged: () {},
          checkpointInput: () async {},
        ),
        '销售出库 / 合成视觉验证数据',
        size: const Size(2400, 1000),
      );
      await tester.tap(find.text('实际交付散件 (3)'));
      await tester.pumpAndSettle();
      expect(find.text('发至加工'), findsWidgets);
      expect(find.text('加工收回'), findsWidgets);
      await captureDialogFixture(
        tester,
        '02-warehouse-components-processing-handover',
        outputDirectory: _output,
      );
      await tester.pumpWidget(const SizedBox());
      draft.dispose();

      await _mount(
        tester,
        repository,
        Builder(
          builder: (context) => UtenButton(
            onPressed: () => showBomDeliveryRuleWindow(
              context,
              rootGoodsId: 'DEMO-PRODUCT',
              edgeId: 'fixed',
              componentName: '合成必装激光组件 / DEMO-FIXED',
              isCurrent: () => true,
            ),
            child: const Text('交付规则'),
          ),
        ),
        '货品资料 / 组装信息 / 合成视觉验证数据',
      );
      await tester.tap(find.text('交付规则'));
      await tester.pumpAndSettle();
      await captureDialogFixture(
        tester,
        '03-master-bom-delivery-rule-window',
        outputDirectory: _output,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );
}
