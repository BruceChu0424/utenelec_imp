/// 审计「数据变更」标签页的字段名可读化字典。
///
/// before/after 快照里的键是数据库列名（snake_case），直接展示普通人看不懂。
/// 这里把常见列名翻译成中文；未收录的键统一显示“其他字段”，原键只留在折叠排查数据中。
library;

import '../../../core/utils/display_datetime.dart';

abstract final class AuditFieldLabels {
  /// 返回中文标签；未收录时安全回退为“其他字段”。
  static String labelOf(String field) =>
      _labels[field] ?? _labels[field.toLowerCase()] ?? '其他字段';

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
  static String valueOf(dynamic value) {
    if (value == null) return '—';
    if (value is bool) return value ? '是' : '否';
    if (value is String) {
      if (value.isEmpty) return '(空)';
      final translated = _valueLabels[value.trim().toLowerCase()];
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

  /// 是否为 UUID 形式的值（通常需要再翻译成名称）。
  static bool looksLikeUuid(Object? value) =>
      value is String && _uuidPattern.hasMatch(value);
}
