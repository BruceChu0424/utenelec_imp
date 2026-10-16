// 可编辑表格内不同控件（输入框/下拉/选择格）必须同高。
//
// 2026-10-06 用户口径：新建委外订货单里下拉框比普通输入框高，行内高低不齐。
// 2026-10-08 修订：全站表格输入格统一为库存盘点「实盘数量」常驻输入格的紧凑
// 尺寸（isDense + UtenEditableGridCellSpec.contentPadding，上下边距 6），
// 本测试改为在真实表格行的注入环境（UtenTableCellInputTheme）下量高。
//
// 基线 = 数量/单价等裸 TextField 格（吃注入主题）。所有格型在其四种业务态
// （空/有值/必填空红/预填黄标/AI 填入）下高度都不得超过基线 ±0.5px；
// 「显式引用规格常量的实盘格同款」必须与注入主题的裸格等高（单一事实源锁）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/required_field_decoration.dart';
import 'package:uten_imp/components/inputs/uten_date_field.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_hints.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_spec.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/shared/widgets/procurement_commercial_grid.dart';
import 'package:uten_imp/shared/widgets/procurement_supplier_cell.dart';

final _outline = find.byWidgetPredicate(
  (widget) =>
      widget is CustomPaint &&
      widget.foregroundPainter?.runtimeType.toString() == '_InputBorderPainter',
);

void main() {
  Future<double> measureCell(WidgetTester tester, WidgetBuilder builder) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: UtenControlTheme(
              child: Padding(
                // UtenEditableGrid 单元格外层同款包裹（h8/v4）。
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: UtenTableCellInputTheme(
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
        ),
      ),
    );
    final fieldRect = tester.getRect(find.byKey(key));
    final paintedRect = tester.getRect(
      find.descendant(of: find.byKey(key), matching: _outline),
    );
    // The outer box alone can satisfy minHeight while its actual outline stays
    // shorter and aligned to the top. Both the paint and its centre must match.
    expect(paintedRect.height, closeTo(fieldRect.height, .5));
    expect(paintedRect.center.dy, closeTo(fieldRect.center.dy, .5));
    return fieldRect.height;
  }

  const items = [
    UtenDropdownItem(value: '1', label: 'RMB'),
    UtenDropdownItem(value: '2', label: 'USD'),
  ];

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      'grid cells retain their height across widgets and states ($platform)',
      (tester) async {
        // 桌面端（用户实际环境）：visualDensity=compact。用例体内改、体内还原——
        // 框架在用例收尾即校验 foundation 调试变量，tearDown 回调已来不及。
        debugDefaultTargetPlatformOverride = platform;
        final heights = <String, double>{};

        heights['TextField 数量（注入主题基线）'] = await measureCell(tester, (ctx) {
          return TextField(
            controller: TextEditingController(text: '10'),
            decoration: const UtenInputDecoration(
              InputDecoration(isDense: true, hintText: '0'),
            ),
          );
        });

        heights['实盘格同款（显式规格常量）'] = await measureCell(tester, (ctx) {
          return TextField(
            controller: TextEditingController(text: '10'),
            textAlign: TextAlign.end,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: UtenInputDecoration(
              InputDecoration(
                isDense: true,
                contentPadding: UtenEditableGridCellSpec.contentPaddingOf(ctx),
                hintText: '0',
              ),
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

        // 实称重量格同款（weight_grid_column 2026-10-10 口径）：黄框预填 + ⓘ + 24 槽
        // 称重按钮。此前 44×44 按钮槽把整格撑高，与同行输入格不齐——本用例锁住
        // 「suffix 24 槽 + 16 图标不再撑高」的规格。
        heights['实称重量格（称重按钮24槽+黄框ⓘ）'] = await measureCell(tester, (ctx) {
          return TextField(
            controller: TextEditingController(text: '20'),
            decoration: applyAutofillHint(
              UtenInputDecoration(
                InputDecoration(
                  isDense: true,
                  suffixIconConstraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  suffixIcon: IconButton(
                    onPressed: () {},
                    constraints: const BoxConstraints.tightFor(
                      width: 24,
                      height: 24,
                    ),
                    padding: const EdgeInsets.all(4),
                    icon: const Icon(Icons.scale_outlined, size: 16),
                  ),
                ),
                info: '系统预填；预估 20 kg，尚未实称。请输入秤上读数。',
              ),
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
              decoration: InputDecoration(
                isDense: true,
                contentPadding: UtenEditableGridCellSpec.contentPaddingOf(ctx),
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

        final baseline = heights['TextField 数量（注入主题基线）']!;
        expect(
          baseline,
          platform == TargetPlatform.windows ? 32 : 48,
          reason: '普通页面主题不能改变表格原有32/48整体尺寸',
        );
        final offenders = <String>[
          for (final entry in heights.entries)
            if ((entry.value - baseline).abs() > 0.5)
              '${entry.key}: ${entry.value} (基线 $baseline)',
        ];
        expect(
          offenders,
          isEmpty,
          reason:
              '表格内控件必须同高：${heights.map((k, v) => MapEntry(k, v.toString()))}',
        );
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  for (final touch in [false, true]) {
    testWidgets(
      'table host keeps icons, dates and default dropdowns compact without hint registration (touch=$touch)',
      (tester) async {
        final controller = TextEditingController(text: '12');
        addTearDown(controller.dispose);
        Widget cell(String key, Widget child) =>
            SizedBox(key: ValueKey(key), width: 180, child: child);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildLightTheme().copyWith(
              platform: touch ? TargetPlatform.android : TargetPlatform.windows,
            ),
            home: Scaffold(
              body: UtenControlTheme(
                child: UtenTableCellInputTheme(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      cell('plain', TextField(controller: controller)),
                      cell(
                        'input',
                        UtenInput(controller: controller, label: '数量'),
                      ),
                      cell(
                        'native-icons',
                        TextField(
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search, size: 18),
                            suffixIcon: IconButton(
                              onPressed: controller.clear,
                              icon: const Icon(Icons.clear),
                            ),
                          ),
                        ),
                      ),
                      cell(
                        'dropdown',
                        UtenDropdownField(
                          label: '币种',
                          value: '1',
                          items: items,
                          onChanged: (_) {},
                        ),
                      ),
                      cell(
                        'date',
                        UtenDateField(
                          label: '交货日期',
                          value: DateTime(2026, 10, 16),
                          onChanged: (_) {},
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final height = tester
            .getSize(find.byKey(const ValueKey('plain')))
            .height;
        expect(height, touch ? 48 : 32);
        for (final key in [
          'plain',
          'input',
          'native-icons',
          'dropdown',
          'date',
        ]) {
          final fieldRect = tester.getRect(find.byKey(ValueKey(key)));
          final paintedRect = tester.getRect(
            find.descendant(of: find.byKey(ValueKey(key)), matching: _outline),
          );
          expect(fieldRect.height, closeTo(height, 0.5), reason: key);
          expect(paintedRect.height, closeTo(height, .5), reason: key);
          expect(
            paintedRect.center.dy,
            closeTo(fieldRect.center.dy, .5),
            reason: key,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
