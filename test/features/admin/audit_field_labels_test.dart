// 审计字段值可读化：ISO 时间戳 →「yyyy-MM-dd HH:mm(北京时间)」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/utils/id_card_utils.dart';
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

  group('employee identity and encrypted columns (V798)', () {
    const table = 'employee_sensitive';
    const labels = {
      'id_type': '证件类型',
      'id_card_enc': '证件号码',
      'id_card_hash': '证件号码查重值',
      'id_card_last4': '证件号码后四位',
      'id_card_check': '证件号校验结果',
      'phone_enc': '手机号',
      'phone_hash': '手机号查重值',
      'birth_date_enc': '出生日期',
      'email_enc': '电子邮箱',
      'office_phone_enc': '办公电话',
      'huji_address_enc': '户籍地址',
      'residence_address_enc': '现居住地址',
      'marital_status_enc': '婚姻状况',
      'political_status_enc': '政治面貌',
      'bank_account_enc': '银行账号',
      'bank_branch_enc': '开户行',
    };
    final server = File(
      'server/src/main/java/com/uten/imp/audit/AuditEventInterpreter.java',
    ).readAsStringSync();

    String checkText(String code) =>
        AuditFieldLabels.valueOf(code, table: table, field: 'id_card_check');

    test('every column has the same Chinese label as the server summary', () {
      for (final MapEntry(:key, :value) in labels.entries) {
        expect(AuditFieldLabels.labelOf(key, table: table), value, reason: key);
        expect(server, contains('values.put("$key", "$value");'), reason: key);
      }
    });

    test(
      'every encrypted column in the schema has a label and hides values',
      () {
        final columns = <String>{};
        final migrations = Directory('server/src/main/resources/db/migration');
        for (final file in migrations.listSync().whereType<File>()) {
          if (!file.path.endsWith('.sql')) continue;
          columns.addAll(
            RegExp(
              r'\b([a-z][a-z0-9_]*_enc)\b',
            ).allMatches(file.readAsStringSync()).map((m) => m.group(1)!),
          );
        }
        expect(columns, containsAll(['id_card_enc', 'birth_date_enc']));
        for (final column in columns) {
          expect(
            AuditFieldLabels.labelOf(column),
            isNot('其他字段'),
            reason: column,
          );
          expect(AuditFieldLabels.hidesValue(column), isTrue, reason: column);
        }
      },
    );

    test('check results read like data entry, never as the stored code', () {
      expect(checkText('valid'), '通过');
      expect(checkText('unchecked'), '未校验');
      expect(checkText('unreadable'), '读取不出来');
      expect(checkText('check_digit'), IdCardProblem.checkDigit.message);
      expect(checkText('length:17'), '身份证号应为18位，当前为17位');
      expect(checkText('length:19'), '身份证号应为18位，当前为19位');
      expect(checkText('character:5'), '身份证号第5位不是数字(只有第18位可以是X)');
      expect(checkText('character:18'), '身份证号第18位只能是数字或X');
      expect(checkText('birth_date'), IdCardProblem.birthDate.message);
      expect(checkText('birth_future'), IdCardProblem.birthFuture.message);
      // 不认识的码只说未通过，绝不把原码显示出来。
      for (final code in ['length:18', 'character:19', 'surprise', 'VALID']) {
        expect(checkText(code), '未通过', reason: code);
      }
      // 与服务端审计摘要的固定说法逐字一致。
      for (final word in ['通过', '未校验', '读取不出来', '未通过']) {
        expect(server, contains('"$word"'), reason: word);
      }
      // 只在 employee_sensitive.id_card_check 这一列翻译。
      expect(
        AuditFieldLabels.valueOf('valid', table: 'rd_tasks', field: 'status'),
        'valid',
      );
    });

    test('every code the database accepts has a plain-Chinese result', () {
      final migration = Directory('server/src/main/resources/db/migration')
          .listSync()
          .whereType<File>()
          .singleWhere(
            (file) =>
                file.path.endsWith('__employee_identity_check_status.sql'),
          );
      final pattern = RegExp(
        r"id_card_check ~ '\^\(([^)]*)\)\$'",
      ).firstMatch(migration.readAsStringSync())!.group(1)!;
      final codes = pattern
          .split('|')
          .map(
            (alternative) => alternative
                .replaceAll('[0-9]{1,3}', '17')
                .replaceAll('[0-9]{1,2}', '5'),
          );
      expect(codes, containsAll(['valid', 'unchecked', 'check_digit']));
      final rawCode = RegExp(r'[a-z]+(_[a-z]+)*(:\d+)?');
      for (final code in codes) {
        final text = checkText(code);
        expect(text, isNot('未通过'), reason: code);
        expect(rawCode.hasMatch(text), isFalse, reason: '$code -> $text');
      }
    });

    test('ciphertext and lookup values never render', () {
      expect(
        AuditFieldLabels.valueOf(
          'ww0EBwMCtestOnly',
          table: table,
          field: 'birth_date_enc',
        ),
        '(内容不显示)',
      );
      expect(
        AuditFieldLabels.valueOf('abc123', table: table, field: 'id_card_hash'),
        '(内容不显示)',
      );
      expect(AuditFieldLabels.valueOf(null, field: 'phone_enc'), '—');
      expect(AuditFieldLabels.hidesValue('id_card_check'), isFalse);
      expect(AuditFieldLabels.hidesValue('id_type'), isFalse);
      expect(AuditFieldLabels.hiddenChangeText(null, 'x'), '已填写(内容不显示)');
      expect(AuditFieldLabels.hiddenChangeText('x', null), '已清空');
      expect(AuditFieldLabels.hiddenChangeText('x', 'y'), '已修改(内容不显示)');
      expect(
        AuditFieldLabels.maskHiddenValues({
          'id_card_check': 'valid',
          'birth_date_enc': 'ww0EBwMCtestOnly',
          'email_enc': null,
          'nested': [
            {'phone_enc': 'ww0EBwMCtestOnly'},
          ],
          '_redacted_changes': ['id_card_enc'],
        }),
        {
          'id_card_check': 'valid',
          'birth_date_enc': '(内容不显示)',
          'email_enc': null,
          'nested': [
            {'phone_enc': '(内容不显示)'},
          ],
          '_redacted_changes': ['id_card_enc'],
        },
      );
    });

    test('redacted column names come back as names only', () {
      expect(
        AuditFieldLabels.redactedFieldsOf({
          '_redacted_changes': ['id_card_enc', ' id_card_hash ', 7, ''],
        }),
        ['id_card_enc', 'id_card_hash'],
      );
      expect(AuditFieldLabels.redactedFieldsOf({'status': 'READY'}), isEmpty);
    });
  });
}
