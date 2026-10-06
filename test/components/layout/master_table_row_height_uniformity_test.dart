// MasterDataTableView 读表单元格高度统一（2026-10-06 行高统一口径）。
//
// 目标行高基准 = 生产调度与进度「进行中」表：全部单行文本格（最高是身份格
// bodyMedium 单行 ≈21px）+ 格子 8×2 纵向留白 → 行 ≈37。任何读表格子里的
// 组件（状态格/内联下拉/动作/徽章）内容高度都不得超过「单行 bodyMedium」，
// 否则该行被撑高、跨页面行高不齐。
//
// 读表里的规范件：内联下拉 = UtenDropdownField(flat)；动作 = UtenTableCellAction；
// 徽章 = 状态列整格底色 + UtenStatusBadge（格内自动降级单行文本）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_goods_identity_cell.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';
import 'package:uten_imp/components/data_display/uten_status_cell_color.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_action.dart';
import 'package:uten_imp/components/inputs/uten_table_cell_hints.dart';
import 'package:uten_imp/core/theme/light_theme.dart';

void main() {
  testWidgets('read-table cell widgets stay within single-line text height', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final theme = buildLightTheme();
    final heights = <String, double>{};

    // 复刻 MasterDataTableView._dataCell 的格子包装（行级 bodySmall 文本样式 +
    // h12/v8 内边距 + 状态列作用域 + 表格格提示作用域），见 master_data_table_view.dart。
    Future<double> measureCell(
      WidgetTester tester,
      WidgetBuilder builder,
    ) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: DefaultTextStyle.merge(
                  style: theme.textTheme.bodySmall!,
                  child: IconTheme.merge(
                    data: IconThemeData(color: theme.colorScheme.onSurface),
                    child: UtenStatusCellScope(
                      enabled: true,
                      child: UtenTableCellHints(
                        child: Builder(
                          builder: (cellContext) => SizedBox(
                            width: 320,
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
        ),
      );
      return tester.getSize(find.byKey(key)).height;
    }

    const items = [
      UtenDropdownItem(value: 'K', label: '持续生产'),
      UtenDropdownItem(value: 'B', label: '分批交货'),
    ];

    // 基准：身份格（参考表「进行中」最高的格子形态）。
    heights['基准-身份格单行'] = await measureCell(
      tester,
      (ctx) => const UtenGoodsIdentityCell(name: 'V5带开关多功能三插插面'),
    );
    heights['默认文本格'] = await measureCell(
      tester,
      (ctx) => const Text('1020-10-12 · 共 3 项'),
    );
    heights['状态格-可点'] = await measureCell(tester, (ctx) {
      return Tooltip(
        message: '点击去领料',
        child: InkWell(
          onTap: () {},
          // 领料/车间任务两页修后的形态：InkWell 直接包内容，不垫垂直内边距。
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.local_shipping_outlined, size: 16),
              SizedBox(width: 4),
              Flexible(child: Text('可领 2 · 去领料')),
            ],
          ),
        ),
      );
    });
    heights['内联下拉-有值'] = await measureCell(
      tester,
      (ctx) => UtenDropdownField(
        flat: true,
        value: 'K',
        items: items,
        onChanged: (_) {},
      ),
    );
    heights['内联下拉-空'] = await measureCell(
      tester,
      (ctx) => UtenDropdownField(
        flat: true,
        value: null,
        hintText: '选择生产路线',
        items: items,
        onChanged: (_) {},
      ),
    );
    heights['内联下拉-必填空'] = await measureCell(
      tester,
      (ctx) => UtenDropdownField(
        flat: true,
        value: null,
        required: true,
        hintText: '选择生产路线',
        items: items,
        onChanged: (_) {},
      ),
    );
    heights['单元格动作'] = await measureCell(
      tester,
      (ctx) => const UtenTableCellAction(label: '固定追加量 · 续报'),
    );
    heights['徽章格内降级'] = await measureCell(
      tester,
      (ctx) =>
          const UtenStatusBadge(label: '待仓库发料', type: UtenStatusBadgeType.info),
    );
    heights['两行文本(反例口径不改)-单行后'] = await measureCell(
      tester,
      (ctx) => const Text(
        '螺丝刀 M6 · 缺 200 · 螺母 M6 · 可领 50 · 垫片 · 待发',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );

    debugDefaultTargetPlatformOverride = null;
    final baseline = heights['基准-身份格单行']!;
    final offenders = <String>[
      for (final entry in heights.entries)
        if (entry.value > baseline + 0.5) '${entry.key}: ${entry.value}',
    ];
    expect(offenders, isEmpty, reason: '读表格子内容不得超过单行基准 $baseline：$heights');
  });
}
