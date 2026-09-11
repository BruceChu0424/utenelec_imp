// 采购订货单行级条款多选联动测试（2026-09 行级商业条款改造后的专属编辑页）：
// 表头不显示供应商/币种/结账方式；勾选多行后点击任一选中行的供应商单元格 →
// 右侧滑入供应商面板（分类树+列表+确定）→ 选一个供应商 → 所有选中行联动填上同一供应商；
// 操作条批量按钮为「统一设置条款 (N)」（一次写供应商+结账方式+币种+汇率+税率）。
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/pages/purchase_order_edit_page.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_grid_columns.dart';
import 'package:uten_imp/features/basic_data/models/reference_method_option.dart';
import 'package:uten_imp/features/basic_data/repositories/reference_method_repository.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets(
    'late supplier defaults do not overwrite a newer supplier choice',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final methods = Completer<List<ReferenceMethodOption>>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(_OrderApi()),
            sessionProvider.overrideWith(_EmptySessionNotifier.new),
            settlementMethodOptionsProvider.overrideWith(
              (ref) => methods.future,
            ),
          ],
          child: const MaterialApp(home: PurchaseOrderEditPage()),
        ),
      );
      Future<void> settleFrames() async {
        for (var i = 0; i < 15; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await settleFrames();
      await tester.tap(find.text('必选供应商').first);
      await settleFrames();
      await tester.tap(find.text('洪武五金'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await settleFrames();
      await tester.tap(find.text('洪武五金').first);
      await settleFrames();
      await tester.tap(find.text('宁海塑胶'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await settleFrames();
      methods.complete(const [
        ReferenceMethodOption(id: 'terms-s1', code: 'CASH', name: 'Cash'),
      ]);
      await tester.pumpAndSettle();
      final grid = tester.widget<UtenEditableGrid<PurchaseGridRow>>(
        find.byType(UtenEditableGrid<PurchaseGridRow>),
      );
      expect(grid.controller.rows.single.supplierId, 's2');
      expect(grid.controller.rows.single.settlementMethodId, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('勾选多行后在任一选中行选供应商，联动填到所有选中行', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_OrderApi()),
          sessionProvider.overrideWith(_EmptySessionNotifier.new),
        ],
        child: const MaterialApp(home: PurchaseOrderEditPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 表头不再有供应商/币种/结账方式字段（行级录入口径）。
    expect(
      find.byWidgetPredicate((w) => w is UtenDropdownField && w.label == '供应商'),
      findsNothing,
    );
    expect(
      find.byWidgetPredicate((w) => w is UtenDropdownField && w.label == '币种'),
      findsNothing,
    );

    // 再加两行（初始自带一条空白行 → 共 3 行）。
    await tester.tap(find.text('添加行'));
    await tester.pump();
    await tester.tap(find.text('添加行'));
    await tester.pump();

    // 勾选前两行（行首选中框在树序里先于表头全选框：at(0..2)=行1..3）。
    final checkboxes = find.byType(Checkbox);
    expect(checkboxes, findsNWidgets(4));
    await tester.tap(checkboxes.at(0));
    await tester.pump();
    await tester.tap(checkboxes.at(1));
    await tester.pumpAndSettle();
    // 2026-09-11「统一设置条款」从工具条撤到行右键菜单（工具条上与右键重复）。
    expect(find.text('统一设置条款 (2)'), findsNothing, reason: '工具条上不该再有它');

    // 点击第一个选中行的供应商单元格（必填未选显示红字提示）→ 右侧滑入供应商面板。
    final cells = find.text('必选供应商');
    expect(cells, findsNWidgets(3));
    await tester.tap(cells.at(0));
    await tester.pumpAndSettle();
    // 面板出现：列表里点选「洪武五金」→ 确定。
    expect(find.text('选择供应商'), findsOneWidget);
    await tester.tap(find.text('洪武五金'));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 两个选中行的单元格显示供应商名（×2），未选中的第三行仍是必填提示。
    expect(find.text('洪武五金'), findsNWidgets(2));
    expect(find.text('必选供应商'), findsOneWidget);

    // 「统一设置条款」的新家：行右键菜单，作用于当前选择集（仍是那 2 行）。
    // 放在流程末尾验证，免得残留的菜单浮层吃掉后续点击。
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('洪武五金').first),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('统一设置条款 (2)'), findsOneWidget, reason: '行右键菜单里要有');
  });
}

class _EmptySessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _OrderApi extends ApiClient {
  _OrderApi() : super(Dio());

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/master/suppliers/dict')) {
      return const [
        {
          'id': 's1',
          'code': 'GY001',
          'name': '洪武五金',
          'status': '使用',
          'defaultSettlementMethodId': 'terms-s1',
        },
        {'id': 's2', 'code': 'GY002', 'name': '宁海塑胶', 'status': '使用'},
      ];
    }
    if (path.contains('/master/supplier-categories/tree')) {
      return const [
        {
          'id': 'cat1',
          'code': 'C1',
          'name': '五金类',
          'level': 0,
          'children': <Map<String, dynamic>>[],
        },
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/master/suppliers')) {
      // 供应商分页（面板 selectableOnly 口径）：仅启用供应商。
      return const {
        'items': <Map<String, dynamic>>[
          {
            'id': 's1',
            'name': '洪武五金',
            'description': '洪武五金制品厂',
            'place': '宁波',
            'linkman': '王经理',
            'mobile': '13800000000',
            'categoryId': 'cat1',
          },
          {
            'id': 's2',
            'name': '宁海塑胶',
            'description': '宁海塑胶有限公司',
            'place': '宁海',
            'categoryId': 'cat1',
          },
        ],
        'page': 1,
        'size': 20,
        'total': 2,
        'totalPages': 1,
      };
    }
    return const {
      'items': <Map<String, dynamic>>[],
      'page': 1,
      'size': 1,
      'total': 0,
      'totalPages': 0,
    };
  }
}
