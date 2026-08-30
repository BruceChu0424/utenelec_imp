// 审计字段值可读化：ISO 时间戳 →「yyyy-MM-dd HH:mm(北京时间)」。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/admin/models/audit_field_labels.dart';

void main() {
  test('formats snapshot timestamps as beijing time', () {
    expect(
      AuditFieldLabels.valueOf('2026-08-29T03:17:00.123456+08:00'),
      '2026-08-29 03:17(北京时间)',
    );
    expect(
      AuditFieldLabels.valueOf('2026-08-28T09:00:00Z'),
      '2026-08-28 17:00(北京时间)',
    );
    expect(
      AuditFieldLabels.valueOf('2026-08-28 09:00:00+00:00'),
      '2026-08-28 17:00(北京时间)',
    );
  });

  test('leaves date-only, plain text and primitives untouched', () {
    expect(AuditFieldLabels.valueOf('2026-09-01'), '2026-09-01');
    expect(AuditFieldLabels.valueOf('加急'), '加急');
    expect(AuditFieldLabels.valueOf(true), '是');
    expect(AuditFieldLabels.valueOf(false), '否');
    expect(AuditFieldLabels.valueOf(null), '—');
    expect(AuditFieldLabels.valueOf(''), '(空)');
    // 已格式化过的值不会被二次改写
    expect(
      AuditFieldLabels.valueOf('2026-08-28 17:00(北京时间)'),
      '2026-08-28 17:00(北京时间)',
    );
  });

  test('unknown internal field names never leak into the main UI label', () {
    expect(AuditFieldLabels.labelOf('unknown_snake_case'), '其他字段');
    expect(AuditFieldLabels.labelOf('status'), '状态');
    expect(AuditFieldLabels.valueOf('READY'), '已就绪');
  });

  test('translates replenishment cancellation audit fields', () {
    expect(AuditFieldLabels.labelOf('cycle_id'), '补产周期');
    expect(AuditFieldLabels.labelOf('authorization_id'), '补产授权');
    expect(AuditFieldLabels.labelOf('reason_code'), '原因代码');
  });
}
