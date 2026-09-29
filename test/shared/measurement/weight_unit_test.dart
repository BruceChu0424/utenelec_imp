// 重量单位契约 (ADR-135 §1): 换算系数、单据行 HALF_UP 4 位舍入 (十进制精确, 与服务端
// WeightUnit.toKgLine 同结果)、带后缀输入解析、自动/固定单位显示、偏好序列化,
// 以及报表合计/单元格的 'weight' / 'count' 类型。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/report/shared/report_cell.dart';
import 'package:uten_imp/features/report/shared/report_column.dart';
import 'package:uten_imp/features/report/shared/report_sort.dart';
import 'package:uten_imp/features/report/shared/report_total.dart';
import 'package:uten_imp/shared/measurement/weight_prefs.dart';
import 'package:uten_imp/shared/measurement/weight_unit.dart';

void main() {
  group('换算系数与单据行舍入', () {
    test('六个单位的千克系数与服务端同表', () {
      expect(WeightUnit.g.kgPerUnit, 0.001);
      expect(WeightUnit.kg.kgPerUnit, 1);
      expect(WeightUnit.t.kgPerUnit, 1000);
      expect(WeightUnit.jin.kgPerUnit, 0.5);
      expect(WeightUnit.lb.kgPerUnit, 0.45359237);
      expect(WeightUnit.oz.kgPerUnit, 0.028349523125);
      expect(WeightUnit.values.map((u) => u.code), [
        'G',
        'KG',
        'T',
        'JIN',
        'LB',
        'OZ',
      ]);
    });

    test('toKgLine 十进制精确 HALF_UP 4 位 (double 乘法会在 .5 边界误舍)', () {
      // 1.00005 x 10000 在 double 里是 10000.4999..., 必须仍进位到 1.0001。
      expect(WeightUnit.kg.toKgLine(1.00005), 1.0001);
      expect(WeightUnit.g.toKgLine(0.05), 0.0001);
      expect(WeightUnit.g.toKgLine(0.04), 0.0);
      expect(WeightUnit.g.toKgLine(850), 0.85);
      expect(WeightUnit.jin.toKgLine(3), 1.5);
      expect(WeightUnit.lb.toKgLine(1), 0.4536);
      expect(WeightUnit.lb.toKgLine(2), 0.9072);
      expect(WeightUnit.oz.toKgLine(5), 0.1417);
      expect(WeightUnit.t.toKgLine(1.2), 1200);
    });

    test('roundKgLine / weightKeyPart: 4 位、去尾零、null 为空串', () {
      expect(roundKgLine(1.23456), 1.2346);
      expect(roundKgLine(null), isNull);
      expect(weightKeyPart(null), '');
      expect(weightKeyPart(12.0), '12');
      expect(weightKeyPart(0.85), '0.85');
      expect(weightKeyPart(1.23456), '1.2346');
    });

    test('editText 把千克值写回录入单位 (不丢 4 位千克精度)', () {
      expect(WeightUnit.kg.editText(0.85), '0.85');
      expect(WeightUnit.g.editText(0.85), '850');
      expect(WeightUnit.g.editText(0.0001), '0.1');
      expect(WeightUnit.t.editText(0.85), '0.00085');
      expect(WeightUnit.lb.editText(1), '2.2046');
      expect(WeightUnit.jin.editText(1.5), '3');
    });
  });

  group('parseWithSuffix', () {
    WeightInput? p(String text, [WeightUnit unit = WeightUnit.kg]) =>
        parseWithSuffix(text, unit);

    test('后缀覆盖列单位', () {
      expect(p('850g')!.unit, WeightUnit.g);
      expect(p('850g')!.kgLine, 0.85);
      expect(p('1.2t')!.kgLine, 1200);
      expect(p('3斤')!.kgLine, 1.5);
      expect(p('2lb')!.kgLine, 0.9072);
      expect(p('0.5 kg')!.kgLine, 0.5);
      expect(p('5 oz')!.kgLine, 0.1417);
      expect(p('3 公斤')!.kgLine, 3);
      expect(p('2磅')!.unit, WeightUnit.lb);
      expect(p('1吨')!.unit, WeightUnit.t);
      expect(p('850克')!.unit, WeightUnit.g);
      expect(p('850g')!.explicitUnit, isTrue);
    });

    test('没后缀按列单位; 千分位与全角照认', () {
      expect(p('12')!.kgLine, 12);
      expect(p('12')!.explicitUnit, isFalse);
      expect(p('12', WeightUnit.g)!.kgLine, 0.012);
      expect(p('1,200 g')!.kgLine, 1.2);
      expect(p('８５０ｇ')!.kgLine, 0.85);
      expect(p('.5')!.kgLine, 0.5);
    });

    test('非法/负数/空串返回 null', () {
      expect(p(''), isNull);
      expect(p('   '), isNull);
      expect(p('abc'), isNull);
      expect(p('-1'), isNull);
      expect(p('12x'), isNull);
      expect(p('1.2.3'), isNull);
    });

    test('WeightUnit.parse 认码/符号/中文名 (大小写不敏感)', () {
      expect(WeightUnit.parse('KG'), WeightUnit.kg);
      expect(WeightUnit.parse('kgs'), WeightUnit.kg);
      expect(WeightUnit.parse('千克'), WeightUnit.kg);
      expect(WeightUnit.parse('Lbs'), WeightUnit.lb);
      expect(WeightUnit.parse('盎司'), WeightUnit.oz);
      expect(WeightUnit.parse('JIN'), WeightUnit.jin);
      expect(WeightUnit.parse('箱'), isNull);
      expect(WeightUnit.fromCode(null), WeightUnit.kg);
    });
  });

  group('显示', () {
    test('自动档按量级: < 1 kg 克, < 1000 kg 千克, 否则吨; 去尾零', () {
      expect(formatWeight(0.85), '850 g');
      expect(formatWeight(0.0005), '0.5 g');
      expect(formatWeight(12.5), '12.5 kg');
      expect(formatWeight(12.0), '12 kg');
      expect(formatWeight(3520), '3.52 t');
      expect(formatWeight(1234.5678), '1.235 t');
      expect(formatWeight(0), '0 kg');
    });

    test('固定单位带千分位; null 显示「—」', () {
      expect(
        formatWeight(12345.678, display: WeightDisplay.kg),
        '12,345.678 kg',
      );
      expect(formatWeight(0.85, display: WeightDisplay.g), '850 g');
      expect(formatWeight(1.5, display: WeightDisplay.jin), '3 斤');
      expect(formatWeight(null), '—');
    });

    test('WeightDisplay 码与导出单位', () {
      expect(WeightDisplay.fromCode('AUTO'), WeightDisplay.auto);
      expect(WeightDisplay.fromCode('kg'), WeightDisplay.kg);
      expect(WeightDisplay.fromCode('bogus'), WeightDisplay.auto);
      expect(WeightDisplay.auto.exportUnit, WeightUnit.kg);
      expect(WeightDisplay.t.exportUnit, WeightUnit.t);
      expect(WeightDisplay.of(WeightUnit.lb), WeightDisplay.lb);
    });
  });

  group('WeightUnitsPrefs', () {
    test('默认 {entry: KG, display: AUTO, sample: G}', () {
      const prefs = WeightUnitsPrefs();
      expect(prefs.toJson(), {'entry': 'KG', 'display': 'AUTO', 'sample': 'G'});
    });

    test('Map 与 JSON 字符串两种形态都能解码; 不认识的码回落默认', () {
      final fromMap = WeightUnitsPrefs.fromJson({
        'entry': 'G',
        'display': 'T',
        'sample': 'OZ',
      });
      expect(fromMap!.entry, WeightUnit.g);
      expect(fromMap.display, WeightDisplay.t);
      expect(fromMap.sample, WeightUnit.oz);
      final fromString = WeightUnitsPrefs.fromJson(
        jsonEncode({'entry': 'LB', 'display': 'AUTO', 'sample': 'G'}),
      );
      expect(fromString!.entry, WeightUnit.lb);
      final fallback = WeightUnitsPrefs.fromJson({'entry': 'x'});
      expect(fallback, const WeightUnitsPrefs());
      expect(WeightUnitsPrefs.fromJson(null), isNull);
      expect(WeightUnitsPrefs.fromJson(42), isNull);
    });
  });

  group('报表 weight / count 类型', () {
    const weight = ReportTotal(
      key: 'weight',
      label: '合计库存重量',
      type: 'weight',
      groupKey: null,
      groups: [ReportTotalGroup(unit: null, value: 3520)],
    );
    ReportTotal count(String key, double value) => ReportTotal(
      key: key,
      label: '重量未知',
      type: 'count',
      groupKey: null,
      groups: [ReportTotalGroup(unit: null, value: value)],
    );

    test('千克按显示单位换算; 未称/估算伴随项并进重量项, 不单独占位', () {
      final entries = reportTotalEntries([
        weight,
        count('weight_unknown_rows', 12),
        count('weight_estimated_rows', 3),
      ]);
      expect(entries, hasLength(1));
      expect(entries.single.label, '合计库存重量');
      expect(entries.single.value, '≈3.52 t (另有 12 项未称)');
    });

    test('固定单位显示; 没有未称项时不带括号', () {
      final entries = reportTotalEntries([
        weight,
        count('weight_unknown_rows', 0),
      ], weightDisplay: WeightDisplay.kg);
      expect(entries.single.value, '3,520 kg');
    });

    test('全部没称 (服务端 SUM 为空) 只报未称项数', () {
      const empty = ReportTotal(
        key: 'weight',
        label: '合计库存重量',
        type: 'weight',
        groupKey: null,
        groups: [],
      );
      expect(
        reportTotalEntries([
          empty,
          count('weight_unknown_rows', 5),
        ]).single.value,
        '5 项未称',
      );
      expect(reportTotalEntry(empty).value, '');
    });

    test('独立 count 项取整, 为 0 时整项隐藏', () {
      expect(reportTotalEntry(count('rows', 1234)).value, '1,234');
      expect(reportTotalEntry(count('rows', 0)).value, '');
    });

    test('单元格: weight 换算 + 估算前缀; null 不显示成 0; 可排序', () {
      const col = ReportColumn(
        key: 'bookWeight',
        label: '账面重量',
        type: 'weight',
      );
      expect(formatReportCell(col, {'bookWeight': 0.85}), '850 g');
      expect(
        formatReportCell(col, {
          'bookWeight': 12.5,
          'bookWeightEstimated': true,
        }),
        '≈12.5 kg',
      );
      expect(formatReportCell(col, {'bookWeight': null}), isNull);
      expect(
        formatReportCell(col, {
          'bookWeight': 12.5,
        }, weightDisplay: WeightDisplay.g),
        '12,500 g',
      );
      const countCol = ReportColumn(key: 'n', label: '次数', type: 'count');
      expect(formatReportCell(countCol, {'n': 1200}), '1,200');
      expect(isSortableReportType('weight'), isTrue);
      expect(isSortableReportType('count'), isTrue);
      expect(isSortableReportType('bool'), isFalse);
    });
  });
}
