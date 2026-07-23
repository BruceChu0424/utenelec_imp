// 员工档案 model（Phase 2）
// 文档：docs/04-数据模型/实体字典.md#employee

/// 员工状态
enum EmployeeStatus {
  active('在职'),
  probation('试用'),
  onLeave('休假'),
  resigned('离职');

  const EmployeeStatus(this.label);
  final String label;
}

/// 用工性质
enum EmploymentType {
  regular('正式'),
  dispatch('劳务派遣'),
  intern('实习');

  const EmploymentType(this.label);
  final String label;
}

/// 性别
enum Gender {
  male('男'),
  female('女');

  const Gender(this.label);
  final String label;
}

/// 任职记录事件类型
enum HistoryEventType { onboard, transfer, resign }

/// 任职记录（员工详情时间线的一格）
class EmploymentHistoryRecord {
  const EmploymentHistoryRecord({
    required this.type,
    required this.title,
    required this.date,
    this.remark,
  });

  final HistoryEventType type;
  final String title;
  final DateTime date;
  final String? remark;
}

/// 员工档案
class Employee {
  const Employee({
    required this.id,
    required this.code,
    required this.fullName,
    required this.gender,
    this.birthDate,
    required this.idCard,
    required this.phone,
    this.email,
    required this.department,
    required this.position,
    this.supervisorName,
    required this.hireDate,
    required this.status,
    required this.employmentType,
    this.contractStart,
    this.contractEnd,
    this.baseSalary,
    this.bankAccount,
    this.history = const [],
  });

  final String id;
  final String code; // 工号
  final String fullName;
  final Gender gender;
  final DateTime? birthDate;
  final String idCard;
  final String phone;
  final String? email;
  final String department;
  final String position;
  final String? supervisorName;
  final DateTime hireDate;
  final EmployeeStatus status;
  final EmploymentType employmentType;
  final DateTime? contractStart;
  final DateTime? contractEnd;
  final num? baseSalary; // 仅 hr/admin 可见
  final String? bankAccount; // 仅 hr/admin 可见
  final List<EmploymentHistoryRecord> history;

  Employee copyWith({
    String? fullName,
    String? code,
    Gender? gender,
    String? phone,
    String? department,
    String? position,
    EmployeeStatus? status,
    EmploymentType? employmentType,
    List<EmploymentHistoryRecord>? history,
  }) {
    return Employee(
      id: id,
      code: code ?? this.code,
      fullName: fullName ?? this.fullName,
      gender: gender ?? this.gender,
      birthDate: birthDate,
      idCard: idCard,
      phone: phone ?? this.phone,
      email: email,
      department: department ?? this.department,
      position: position ?? this.position,
      supervisorName: supervisorName,
      hireDate: hireDate,
      status: status ?? this.status,
      employmentType: employmentType ?? this.employmentType,
      contractStart: contractStart,
      contractEnd: contractEnd,
      baseSalary: baseSalary,
      bankAccount: bankAccount,
      history: history ?? this.history,
    );
  }
}

// —— 脱敏 helpers（UI 层展示用，敏感字段不向无权角色明文）——

String maskPhone(String p) {
  if (p.length < 11) return p;
  return '${p.substring(0, 3)}****${p.substring(7)}';
}

String maskIdCard(String id) {
  if (id.length < 8) return id;
  return '${id.substring(0, 3)}********${id.substring(id.length - 2)}';
}

String maskBank(String b) {
  if (b.length < 4) return b;
  return '**** ${b.substring(b.length - 4)}';
}
