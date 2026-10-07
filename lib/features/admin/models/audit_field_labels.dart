/// 审计「数据变更」标签页的字段名可读化字典。
///
/// before/after 快照里的键是数据库列名（snake_case），直接展示普通人看不懂。
/// 这里把常见列名翻译成中文；未收录的键统一显示“其他字段”，原键只留在折叠排查数据中。
///
/// 服务端只给整条记录一句 changeSummary(最多 6 项)，不给逐列的中文，所以「数据变更」
/// 标签页的逐列名称和取值由这里翻译；密文列(*_enc)和查重值只说改了，从不显示内容。
library;

import '../../../core/utils/display_datetime.dart';
import '../../../core/utils/id_card_utils.dart';

abstract final class AuditFieldLabels {
  /// 数据库触发器在快照里写的键：敏感列变了只记列名(值是列名数组)，不记内容。
  static const String redactedChangesKey = '_redacted_changes';

  /// 不显示内容的列，取值处统一写这句。
  static const String hiddenValueText = '(内容不显示)';

  /// 由证件号、手机号、口令算出的查重值/摘要：不是密文，但同样不给人看。
  static const Set<String> _hiddenValueFields = {
    'id_card_hash',
    'phone_hash',
    'password_hash',
    'token_hash',
    'preview_token_hash',
    'code_hash',
  };

  /// 这一列的内容是否不能显示：密文列(列名以 _enc 结尾)和查重值。
  static bool hidesValue(String field) {
    final key = field.trim().toLowerCase();
    return key.endsWith('_enc') || _hiddenValueFields.contains(key);
  }

  /// 不显示内容的列改了(含触发器只记了列名的敏感列)。
  static const String hiddenModifiedText = '已修改(内容不显示)';

  /// 不显示内容的列这次变了什么：从无到有、被清空或改了，只说动作不说内容。
  static String hiddenChangeText(Object? before, Object? after) {
    if (before == null && after != null) return '已填写(内容不显示)';
    if (before != null && after == null) return '已清空';
    return hiddenModifiedText;
  }

  /// 快照里 [redactedChangesKey] 列出的列名(只有列名，没有内容)。
  static List<String> redactedFieldsOf(Map<String, dynamic> after) {
    final names = after[redactedChangesKey];
    if (names is! List) return const [];
    return [
      for (final name in names)
        if (name is String && name.trim().isNotEmpty) name.trim(),
    ];
  }

  /// 原始快照给人看之前，把不显示内容的列换成 [hiddenValueText](空值保持空值)。
  static Object? maskHiddenValues(Object? json) {
    if (json is Map) {
      return {
        for (final entry in json.entries)
          entry.key:
              entry.key is String &&
                  hidesValue(entry.key as String) &&
                  entry.value != null
              ? hiddenValueText
              : maskHiddenValues(entry.value),
      };
    }
    if (json is List) return [for (final item in json) maskHiddenValues(item)];
    return json;
  }

  /// 返回中文标签；未收录时安全回退为“其他字段”。
  ///
  /// [table] 是审计行的 target_type(数据变更即表名)：同名列在个别表里含义
  /// 不同(如 goods_bom_items.qty 是「设计使用数量」而非泛指的「数量」)，
  /// 先查表限定字典，再查通用字典。
  static String labelOf(String field, {String? table}) =>
      (table == null ? null : _tableLabels['$table.$field']) ??
      _labels[field] ??
      _labels[field.toLowerCase()] ??
      '其他字段';

  /// 表限定的列名标签(键 = `表名.列名`)，只收与通用字典含义不同或只属于
  /// 一张表的列；与服务端 AuditEventInterpreter.tableFieldLabels() 逐字一致。
  static const Map<String, String> _tableLabels = {
    // ADR-129：BOM 的 qty 是工程人员维护的设计值；真实使用数量另由学习累计。
    'goods_bom_items.qty': '设计使用数量',
    'goods_bom_items.learning_profile_goods_id': '系统学习标记',
    'goods_bom_items.learning_unit_id': '系统学习时的组件单位',
    'goods_bom_items.learning_released_at': '人工删除后不再自动加回的时间',
    // 员工资料核对四张表(V810)：以下条目与服务端 AuditEventInterpreter.tableFieldLabels()
    // 逐字一致；密文列(old/new/candidates_value_enc)沿用 hidesValue 的 *_enc 隐藏机制。
    'employee_reconcile_plans.source': '核对来源',
    'employee_reconcile_plans.origin': '生成入口',
    'employee_reconcile_plans.actor_user_id': '创建人账号',
    'employee_reconcile_plans.actor_employee_id': '创建人员工档案',
    'employee_reconcile_plans.counts': '统计',
    'employee_reconcile_plans.closed_reason': '关闭原因',
    'employee_reconcile_plans.applying_until': '更正执行租约至',
    'employee_reconcile_plans.expires_at': '有效期至',
    'employee_reconcile_plans.last_applied_at': '最近执行更正时间',
    'employee_reconcile_plans.purged_at': '未执行值清空时间',
    'employee_reconcile_plan_rows.row_no': '行号',
    'employee_reconcile_plan_rows.employee_version': '生成时员工版本',
    'employee_reconcile_plan_rows.kind': '行类型',
    'employee_reconcile_plan_rows.notice_codes': '提示码',
    'employee_reconcile_plan_rows.result': '行结果',
    'employee_reconcile_plan_items.item_no': '项号',
    'employee_reconcile_plan_items.field_code': '字段',
    'employee_reconcile_plan_items.write_path': '写入路径',
    'employee_reconcile_plan_items.required_permissions': '所需权限',
    'employee_reconcile_plan_items.diff_positions': '差异位置',
    'employee_reconcile_plan_items.suspect_positions': '可疑位置',
    'employee_reconcile_plan_items.basis_code': '修复依据',
    'employee_reconcile_plan_items.tier': '把握档位',
    'employee_reconcile_plan_items.probability': '把握度',
    'employee_reconcile_plan_items.preselected': '是否预选',
    'employee_reconcile_plan_items.note_codes': '提示码',
    'employee_reconcile_plan_items.applied_origin': '采用方式',
    'employee_reconcile_plan_items.outcome': '执行结果',
    'employee_reconcile_plan_items.outcome_code': '执行结果代码',
    'employee_reconcile_plan_items.outcome_message': '执行结果说明',
    'employee_reconcile_plan_items.apply_id': '更正回执',
    'employee_reconcile_plan_items.applied_at': '执行时间',
    'employee_reconcile_applies.round_no': '轮次',
    'employee_reconcile_applies.request_id': '请求标识',
    'employee_reconcile_applies.actor_user_id': '执行人账号',
    'employee_reconcile_applies.counts': '统计',
    'employee_reconcile_applies.result': '执行结果',
    'employee_reconcile_applies.started_at': '开始时间',
    'employee_reconcile_applies.finished_at': '结束时间',
  };

  static const Map<String, String> _labels = {
    // 通用审计/状态列
    'id': '主键 ID',
    'created_at': '创建时间',
    'updated_at': '更新时间',
    'created_by': '创建人',
    'updated_by': '最后修改人',
    'is_deleted': '是否已删除',
    'deleted_at': '删除时间',
    'deleted_by': '删除操作人',
    'version': '版本号',
    'status': '状态',
    'remark': '备注',
    'remarks': '备注',
    'note': '备注',
    'sort_order': '排序号',
    'code': '编号',
    'name': '名称',
    'title': '标题',
    'type': '类型',
    'category': '分类',
    'level': '级别',
    'path': '路径',

    // 员工 / 组织
    'full_name': '姓名',
    'gender': '性别',
    'department_id': '所属部门',
    'position_id': '所属职位',
    'supervisor_id': '直属上级',
    'hire_date': '入职日期',
    'confirmed_at': '转正日期',
    'employment_type': '用工类型',
    'work_location': '工作地点',
    'seat_no': '工位号',
    'attendance_group': '考勤组',
    'paper_archive_no': '纸质档案号',
    'birth_month_day': '生日(月-日)',
    'avatar_storage_key': '头像',
    'legacy_id': '旧系统 ID',
    'legacy_category': '旧系统分类',
    'resign_date': '离职日期',
    'offboard_reason': '离职原因',
    'birth_date': '出生日期',
    'ethnicity': '民族',
    'political_status': '政治面貌',
    'marital_status': '婚姻状况',

    // 员工证件与加密信息(employee_sensitive)：名称与服务端审计摘要逐字一致；
    // 密文列和查重值只说改了，内容见 hidesValue。
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
    // 其它加密列：薪酬、资料修改申请的前后内容、访客车牌。
    'base_salary_enc': '基本工资',
    'perf_salary_enc': '绩效工资',
    'social_insurance_base_enc': '社保基数',
    'housing_fund_base_enc': '公积金基数',
    'allowance_standard_enc': '补贴标准',
    'old_value_enc': '修改前内容',
    'new_value_enc': '修改后内容',
    // 证件核对计划的候选新值(ADR-160/V810)，密文保存、只说改了。
    'candidates_enc': '候选证件号',
    'plate_no_enc': '车牌号',

    // 用户账号 / 权限
    'login_account': '登录账号',
    'employee_id': '关联员工',
    'must_change_password': '下次登录须改密',
    'failed_attempts': '连续失败次数',
    'locked_until': '锁定至',
    'last_login_at': '最近登录时间',
    'last_password_changed_at': '最近改密时间',
    'temp_password_expires_at': '临时密码有效期',
    'is_super_admin': '超级管理员',
    'remote_access': '允许外网访问',
    'auth_version': '授权版本号',
    'role_id': '角色',
    'permission_id': '权限项',
    'user_id': '用户',
    'department': '部门',

    // 基础资料
    'unit_id': '单位',
    'color_id': '颜色',
    'currency_id': '币种',
    'warehouse_id': '仓库',
    'category_id': '分类',
    'goods_id': '货品',
    'client_id': '客户',
    'supplier_id': '供应商',
    'account_id': '资金账户',
    'payment_style_id': '结算方式',
    'series': '系列',
    'stock_place': '库位号',
    'spec': '规格',
    'specification': '规格型号',
    'barcode': '条码',
    'description': '描述',
    'exchange_rate': '汇率',
    'settlement_method': '结算方式',
    'mould_id': '模具',
    'rear_insert_code': '后模镶件编号',
    'paper': '备注（货品）',
    // 采购批量口径（V575）：软约束，下达采购按此预填默认数量。
    'min_order_qty': '最小起订量',
    'order_multiple_qty': '订货倍数',

    // 单据通用
    'doc_no': '单据编号',
    'bill_no': '单据编号',
    'order_no': '订单编号',
    'doc_date': '单据日期',
    'biz_date': '业务日期',
    'qty': '数量',
    'quantity': '数量',
    'price': '单价',
    'unit_price': '单价',
    'amount': '金额',
    'total_amount': '合计金额',
    'tax_rate': '税率',
    'tax_amount': '税额',
    'discount': '折扣',
    'approved_at': '审批时间',
    'approved_by': '审批人',
    'submitted_at': '提交时间',
    'submitted_by': '提交人',
    'confirmed_at_doc': '确认时间',
    'expected_date': '预计日期',
    'delivery_date': '交付日期',
    'source_id': '来源单据',
    'source_type': '来源类型',

    // 生产
    'plan_no': '计划编号',
    'workshop': '车间',
    'workshop_id': '车间',
    'planned_qty': '计划数量',
    'completed_qty': '完成数量',
    'start_date': '开始日期',
    'end_date': '结束日期',
    'due_date': '交期',
    'priority': '优先级',
    'analysis_id': '物料分析',
    'cycle_id': '补产周期',
    'authorization_id': '补产授权',
    'reason_code': '原因代码',
    'from_material_id': '被借用物料',
    'to_material_id': '借出物料',
    'borrow_qty': '借用数量',
    'last_effective_qty': '最近生效数量',
    'revoked_by': '撤销人',
    'revoked_at': '撤销时间',
    'revoke_reason': '撤销原因',
    // BOM 设计/真实使用数量(ADR-129)。
    'design_bom_qty': '设计使用数量',
    'actual_bom_qty': '真实使用数量',
    'usage_basis': '计算采用',
    'usage_reason': '按设计使用数量的原因',
    'usage_sample_count': '有效生产批次',
    'usage_defect_rate': '采用时的不良率',
    // 日报登记的不良数：只作记录，不计入良品数量。
    'defect_qty': '不良数',
    'counted_leftover_qty': '实际剩余(清点)',
    'allowed_overproduction_rate': '允许超产比例',
    'allowed_overproduction_rate_source': '超产比例来源',

    // 财务
    'payee': '收款方',
    'payer': '付款方',
    'bank_account': '银行账号',
    'voucher_no': '凭证号',
    'subject_code': '科目编码',
    'debit': '借方金额',
    'credit': '贷方金额',
    'period': '会计期间',

    // 系统设置 / 审计
    'setting_key': '设置项',
    'setting_value': '设置值',
    'risk_level': '风险等级',
    'event_category': '事件类型',
    'event_source': '记录来源',
  };

  /// 值可读化：布尔/空值翻译；ISO 时间戳转「yyyy-MM-dd HH:mm(北京时间)」；
  /// UUID 保持原样(由调用方决定是否再按字典解析)。
  ///
  /// 业务编码只在知道 [table] 与 [field] 时按表列翻译(同一个 DESIGN 在研发
  /// 任务分类里是「设计」，在物料分析里才是「按设计使用数量」)；通用字典只收
  /// 各表含义都一样的状态值。知道 [field] 且是不显示内容的列(见 [hidesValue])时，
  /// 有值一律只给 [hiddenValueText]。
  static String valueOf(dynamic value, {String? table, String? field}) {
    if (value == null) return '—';
    if (field != null && hidesValue(field)) return hiddenValueText;
    if (value is bool) return value ? '是' : '否';
    if (value is String) {
      if (value.isEmpty) return '(空)';
      if (table == _idCardCheckTable && field == _idCardCheckField) {
        return idCardCheckText(value);
      }
      final key = value.trim().toLowerCase();
      final translated =
          (table == null || field == null
              ? null
              : _tableValueLabels['$table.$field']?[key]) ??
          _valueLabels[key];
      if (translated != null) return translated;
      if (_dateTimePattern.hasMatch(value)) {
        final formatted = DisplayDateTime.beijing(value);
        if (formatted.isNotEmpty) {
          return formatted.replaceFirst('(北京)', '(北京时间)');
        }
      }
    }
    return value.toString();
  }

  /// 快照字段值里的 ISO 时间戳(含可选秒/毫秒/偏移；日期-only 不匹配)。
  static final RegExp _dateTimePattern = RegExp(
    r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}:?\d{2})?$',
  );

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static const Map<String, String> _valueLabels = {
    'ready': '已就绪',
    'dispatched': '已下达',
    'pending': '待处理',
    'draft': '草稿',
    'submitted': '已提交',
    'approved': '已批准',
    'rejected': '已驳回',
    'completed': '已完成',
    'cancelled': '已取消',
    'canceled': '已取消',
    'enabled': '已启用',
    'disabled': '已停用',
    'active': '有效',
    'inactive': '无效',
    'success': '成功',
    'failure': '失败',
    'failed': '失败',
  };

  /// 表限定的值标签(键 = `表名.列名`，值按小写编码)：只在这张表这一列翻译。
  static const Map<String, Map<String, String>> _tableValueLabels = {
    // BOM 用量采用依据与原因(ADR-129)，原因与界面说明同一措辞。
    'production_material_analysis_materials.usage_basis': {
      'design': '按设计使用数量',
      'actual': '按真实使用数量',
    },
    'production_material_analysis_materials.usage_reason': {
      'no_data': '还没有已完工且核清余料的生产数据',
      'not_linear': '整包或固定批次不能按平均用量算',
      'output_unit_changed': '父件单位变了，需重新学习',
      'subcontract_outbound': '上级委外件按领料把这个物料发给委外商，按委外合同(设计)用量',
    },
    'production_plan_items.allowed_overproduction_rate_source': {
      'default': '系统默认',
      'explicit': '人工确认',
    },
  };

  static const _idCardCheckTable = 'employee_sensitive';
  static const _idCardCheckField = 'id_card_check';

  /// 员工证件号校验结果的存储码 → 中文：valid 通过、unchecked 未校验、unreadable 读取
  /// 不出来；其余是问题码(如 check_digit、length:17)，还原成录入时当场看到的同一句
  /// 说明([IdCardProblem.fromCode])；不认识的码只说「未通过」，不把原码显示出来。
  static String idCardCheckText(String code) {
    final value = code.trim();
    return switch (value) {
      'valid' => '通过',
      'unchecked' => '未校验',
      'unreadable' => '读取不出来',
      _ => IdCardProblem.fromCode(value)?.message ?? '未通过',
    };
  }

  /// 是否为 UUID 形式的值（通常需要再翻译成名称）。
  static bool looksLikeUuid(Object? value) =>
      value is String && _uuidPattern.hasMatch(value);
}
