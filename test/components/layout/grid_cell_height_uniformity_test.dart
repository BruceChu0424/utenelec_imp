// 可编辑表格内不同控件（输入框/下拉/选择格）必须同高（2026-10-06 用户口径：
// 新建委外订货单里下拉框比普通输入框高，行内高低不齐）。
//
// 基线 = 数量/单价等 TextField 格（isDense + 主题装饰）。所有格型在其四种
// 业务态（空/有值/必填空红/预填黄标/AI 填入）下高度都不得超过基线 ±0.5px。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/required_field_decoration.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_hints.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart'
    show UtenEditableGridCellSpec;
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/widgets/procurement_commercial_grid.dart';
import 'package:uten_imp/shared/widgets/procurement_supplier_cell.dart';

void main() {
  Future<double> measureCell(WidgetTester tester, WidgetBuilder builder) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              // UtenEditableGrid 单元格外层同款包裹（h8/v4）。
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: UtenTableCellHints(
                child: Builder(
                  builder: (cellContext) => SizedBox(
                    width: 160,
                    child: KeyedSubtree(
                      key: key,
                      child: Builder(builder: builder),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // 短文本不折行：格子高度即控件自然高度。
    return tester.getSize(find.byKey(key)).height;
  }

  const items = [
    UtenDropdownItem(value: '1', label: 'RMB'),
    UtenDropdownItem(value: '2', label: 'USD'),
  ];

  testWidgets('grid cells share one height across widgets and states', (
    tester,
  ) async {
    // 桌面端（用户实际环境）：visualDensity=compact。用例体内改、体内还原——
    // 框架在用例收尾即校验 foundation 调试变量，tearDown 回调已来不及。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final heights = <String, double>{};

    heights['TextField 数量'] = await measureCell(tester, (ctx) {
      return TextField(
        controller: TextEditingController(text: '10'),
        decoration: const UtenInputDecoration(
          InputDecoration(isDense: true, hintText: '0'),
        ),
      );
    });

    heights['TextField 预填黄标（汇率）'] = await measureCell(tester, (ctx) {
      return TextField(
        controller: TextEditingController(text: '1'),
        decoration: applyAutofillHint(
          const UtenInputDecoration(InputDecoration(isDense: true)),
          Theme.of(ctx),
          autofilled: true,
        ),
      );
    });

    heights['下拉 空'] = await measureCell(
      tester,
      (ctx) => UtenDropdownField(
        dense: true,
        value: null,
        items: items,
        onChanged: (_) {},
        hintText: '点击选择',
      ),
    );
    heights['下拉 有值'] = await measureCell(
      tester,
      (ctx) => UtenDropdownField(
        dense: true,
        value: '1',
        items: items,
        onChanged: (_) {},
      ),
    );
    heights['下拉 必填空红'] = await measureCell(
      tester,
      (ctx) => UtenDropdownField(
        dense: true,
        value: null,
        items: items,
        onChanged: (_) {},
        required: true,
      ),
    );
    heights['下拉 预填黄标'] = await measureCell(
      tester,
      (ctx) => UtenDropdownField(
        dense: true,
        value: '1',
        items: items,
        onChanged: (_) {},
        autofilled: true,
      ),
    );
    heights['下拉 错误态'] = await measureCell(
      tester,
      (ctx) => UtenDropdownField(
        dense: true,
        value: '1',
        items: items,
        onChanged: (_) {},
        errorMessage: '不可用',
      ),
    );
    heights['下拉 禁用态'] = await measureCell(
      tester,
      (ctx) => UtenDropdownField(
        dense: true,
        value: '1',
        items: items,
        onChanged: (_) {},
        enabled: false,
      ),
    );

    heights['商业条款下拉格'] = await measureCell(
      tester,
      (ctx) => const ProcurementTermDropdownCell(
        value: '1',
        entries: {'1': 'RMB', '2': 'USD'},
      ),
    );

    heights['委外商选择格'] = await measureCell(
      tester,
      (ctx) =>
          const ProcurementSupplierCell(value: 's1', entries: {'s1': 'A社'}),
    );
    heights['委外商选择格 必填空'] = await measureCell(
      tester,
      (ctx) => const ProcurementSupplierCell(
        value: null,
        entries: {'s1': 'A社'},
        requiredEmpty: true,
      ),
    );

    heights['货品名称选择格'] = await measureCell(tester, (ctx) {
      return InkWell(
        onTap: () {},
        child: InputDecorator(
          // 名称保持全站身份格字号（bodyMedium w600），垂直 +1 对齐同行输入格。
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: UtenEditableGridCellSpec.pickerCellPadding,
          ),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'M6x20',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1.5,
                  ),
                ),
              ),
              Icon(
                Icons.search_rounded,
                size: 16,
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      );
    });

    final baseline = heights['TextField 数量']!;
    final offenders = <String>[
      for (final entry in heights.entries)
        if ((entry.value - baseline).abs() > 0.5)
          '${entry.key}: ${entry.value} (基线 $baseline)',
    ];
    expect(
      offenders,
      isEmpty,
      reason: '表格内控件必须同高：${heights.map((k, v) => MapEntry(k, v.toString()))}',
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
