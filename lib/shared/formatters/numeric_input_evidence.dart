import '../../core/formatters/exact_number_text.dart';
import 'exact_decimal.dart';

/// Read-only provenance from the authorized owning document. No arithmetic,
/// mutation endpoint, balance or unit inference is introduced here.
String? numericInputEvidenceTooltip(
  List<Map<String, dynamic>> values,
  String fieldKey,
) {
  final lines = <String>[];
  for (final evidence in values) {
    if (evidence['fieldKey'] != fieldKey) continue;
    final raw = financeExactDecimal(evidence['originalDecimal']),
        recorded = financeExactDecimal(evidence['recordedDecimal']);
    if (raw == null || recorded == null) continue;
    String unit(Object? value) {
      if (value is! Map) return '';
      final code = value['code']?.toString();
      return code == null
          ? '单位按原单核对'
          : value['kind'] == 'MASS_PER_UNIT'
          ? '${code == 'KG' ? 'kg' : code}/原基本单位'
          : value['kind'] == 'RATIO' && code == 'PERCENT_POINTS'
          ? '%'
          : code == 'KG'
          ? 'kg'
          : code;
    }

    lines.add(
      '原提交值：${exactNumberDisplay(raw, groupThousands: true)} ${unit(evidence['originalUnit'])}；实际记录：${exactNumberDisplay(recorded, groupThousands: true)} ${unit(evidence['recordedUnit'])}',
    );
    final policy = evidence['usedPolicy'];
    if (policy is Map) {
      final choices = <String>{};
      for (final value in policy.values) {
        if (value is Map &&
            value['scale'] is int &&
            const {'HALF_UP', 'DOWN'}.contains(value['rounding'])) {
          choices.add(
            '保留${value['scale']}位，${value['rounding'] == 'HALF_UP' ? '四舍五入' : '直接截取，不进位'}',
          );
        }
      }
      if (choices.isNotEmpty) lines.add('本次已确认：${choices.join('；')}。');
    }
    if (lines.length >= 20) {
      lines.add('其余原提交证据保留在本单。');
      break;
    }
  }
  return lines.isEmpty ? null : lines.join('\n');
}
