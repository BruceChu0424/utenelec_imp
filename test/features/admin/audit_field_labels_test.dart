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

  test('BOM qty is the design usage only on goods_bom_items (ADR-129)', () {
    expect(AuditFieldLabels.labelOf('qty', table: 'goods_bom_items'), '设计使用数量');
    // 其它表的 qty 仍是泛指的「数量」，不传表名也不变。
    expect(AuditFieldLabels.labelOf('qty', table: 'sales_order_items'), '数量');
    expect(AuditFieldLabels.labelOf('qty'), '数量');
    // 学习列只属于 goods_bom_items，措辞与服务端审计摘要逐字一致。
    expect(
      AuditFieldLabels.labelOf('learning_unit_id', table: 'goods_bom_items'),
      '系统学习时的组件单位',
    );
    expect(
      AuditFieldLabels.labelOf(
        'learning_released_at',
        table: 'goods_bom_items',
      ),
      '人工删除后不再自动加回的时间',
    );
    expect(
      AuditFieldLabels.labelOf(
        'learning_profile_goods_id',
        table: 'goods_bom_items',
      ),
      '系统学习标记',
    );
    expect(AuditFieldLabels.labelOf('design_bom_qty'), '设计使用数量');
    expect(AuditFieldLabels.labelOf('actual_bom_qty'), '真实使用数量');
    expect(AuditFieldLabels.labelOf('counted_leftover_qty'), '实际剩余(清点)');
    expect(
      AuditFieldLabels.labelOf('allowed_overproduction_rate_source'),
      '超产比例来源',
    );
  });

  test('daily report defects and the adopted defect rate read plainly', () {
    // 措辞与服务端审计摘要逐字一致。
    expect(
      AuditFieldLabels.labelOf(
        'defect_qty',
        table: 'production_daily_report_items',
      ),
      '不良数',
    );
    expect(AuditFieldLabels.labelOf('defect_qty'), '不良数');
    expect(
      AuditFieldLabels.labelOf(
        'usage_defect_rate',
        table: 'production_material_analysis_materials',
      ),
      '采用时的不良率',
    );
  });

  test('ADR-129 codes are translated only on their own table column', () {
    const analysis = 'production_material_analysis_materials';
    expect(
      AuditFieldLabels.valueOf('ACTUAL', table: analysis, field: 'usage_basis'),
      '按真实使用数量',
    );
    expect(
      AuditFieldLabels.valueOf(
        'NOT_LINEAR',
        table: analysis,
        field: 'usage_reason',
      ),
      '整包或固定批次不能按平均用量算',
    );
    expect(
      AuditFieldLabels.valueOf(
        'EXPLICIT',
        table: 'production_plan_items',
        field: 'allowed_overproduction_rate_source',
      ),
      '人工确认',
    );
    // 研发任务分类 DESIGN 不能被翻成 BOM 用量的说法；不知道表列时也不翻。
    expect(
      AuditFieldLabels.valueOf('DESIGN', table: 'rd_tasks', field: 'category'),
      'DESIGN',
    );
    expect(AuditFieldLabels.valueOf('DESIGN'), 'DESIGN');
    expect(AuditFieldLabels.valueOf('DEFAULT'), 'DEFAULT');
    // 通用状态值照常翻译。
    expect(
      AuditFieldLabels.valueOf('READY', table: 'rd_tasks', field: 'status'),
      '已就绪',
    );
  });
}
