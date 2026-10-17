import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/search/column_keyword_policy.dart';

class _Row extends EditableGridRow {}

void main() {
  test(
    'master and editing grids use the same business meaning for text keywords',
    () {
      for (final (key, label, expected) in [
        ('name', '货品名称', true),
        ('code', '编号', true),
        ('color', '颜色', true),
        ('model', '型号', true),
        ('series', '系列', true),
        ('supplier', '供应商', true),
        ('remark', '备注', true),
        ('deliveryDate', '交期', false),
        ('quantity', '数量', false),
        ('amount', '金额', false),
        ('status', '状态', false),
        ('currency', '币种', false),
        ('unitId', '单位', false),
        ('sourceType', '来源', false),
        ('action', '操作', false),
      ]) {
        expect(
          supportsColumnKeywordSearch(key: key, label: label),
          expected,
          reason: label,
        );
        expect(
          MasterColumnDef<_Row>(
            key: key,
            label: label,
            width: 100,
            value: (_) => '',
          ).supportsKeywordSearch,
          expected,
          reason: 'master $label',
        );
        expect(
          EditableGridColumn<_Row>(
            key: key,
            label: label,
            width: 100,
            textOf: (_) => '',
            cellBuilder: (_, _) => const SizedBox.shrink(),
          ).supportsKeywordSearch,
          expected,
          reason: 'grid $label',
        );
      }
    },
  );

  test(
    'business overrides cannot fabricate an editing-grid text source or turn numeric cells into keyword fields',
    () {
      expect(
        supportsColumnKeywordSearch(key: 'name', label: '名称', type: 'date'),
        isFalse,
      );
      expect(
        supportsColumnKeywordSearch(key: 'name', label: '名称', override: false),
        isFalse,
      );
      expect(
        EditableGridColumn<_Row>(
          key: 'custom',
          label: '自定义',
          width: 100,
          columnSearchEnabled: true,
          cellBuilder: (_, _) => const SizedBox.shrink(),
        ).supportsKeywordSearch,
        isFalse,
      );
      expect(
        EditableGridColumn<_Row>(
          key: 'quantity',
          label: '数量',
          width: 100,
          numeric: true,
          columnSearchEnabled: true,
          textOf: (_) => '10',
          cellBuilder: (_, _) => const SizedBox.shrink(),
        ).supportsKeywordSearch,
        isFalse,
      );
    },
  );
}
