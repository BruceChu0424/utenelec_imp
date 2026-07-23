// 员工 API 模型（对应后端 EmployeeListItem / EmployeeDetail / 入职 payload）。

/// 员工列表项（无敏感 PII）。
class EmployeeSummary {
  const EmployeeSummary({
    required this.id,
    required this.code,
    required this.fullName,
    this.gender,
    this.departmentName,
    this.positionName,
    this.status,
    this.employmentType,
    this.hireDate,
  });

  final String id;
  final String code;
  final String fullName;
  final String? gender;
  final String? departmentName;
  final String? positionName;
  final String? status;
  final String? employmentType;
  final String? hireDate; // yyyy-MM-dd

  factory EmployeeSummary.fromJson(Map<String, dynamic> json) => EmployeeSummary(
        id: json['id'] as String,
        code: json['code'] as String,
        fullName: json['fullName'] as String,
        gender: json['gender'] as String?,
        departmentName: json['departmentName'] as String?,
        positionName: json['positionName'] as String?,
        status: json['status'] as String?,
        employmentType: json['employmentType'] as String?,
        hireDate: json['hireDate'] as String?,
      );
}

class EmergencyContactView {
  const EmergencyContactView({this.id, this.name, this.phone, this.relationship});
  final String? id;
  final String? name;
  final String? phone; // 已按角色脱敏
  final String? relationship;

  factory EmergencyContactView.fromJson(Map<String, dynamic> json) => EmergencyContactView(
        id: json['id'] as String?,
        name: json['name'] as String?,
        phone: json['phone'] as String?,
        relationship: json['relationship'] as String?,
      );
}

class EmploymentHistoryView {
  const EmploymentHistoryView({
    this.id,
    this.eventType,
    this.fromDeptName,
    this.toDeptName,
    this.eventDate,
    this.remark,
  });
  final String? id;
  final String? eventType;
  final String? fromDeptName;
  final String? toDeptName;
  final String? eventDate;
  final String? remark;

  factory EmploymentHistoryView.fromJson(Map<String, dynamic> json) => EmploymentHistoryView(
        id: json['id'] as String?,
        eventType: json['eventType'] as String?,
        fromDeptName: json['fromDeptName'] as String?,
        toDeptName: json['toDeptName'] as String?,
        eventDate: json['eventDate'] as String?,
        remark: json['remark'] as String?,
      );
}

/// 员工详情（敏感字段已由后端按角色脱敏）。
class EmployeeProfile {
  const EmployeeProfile({
    required this.id,
    required this.code,
    required this.fullName,
    this.gender,
    this.idType,
    this.birthDate,
    this.ethnicity,
    this.politicalStatus,
    this.maritalStatus,
    this.hujiAddress,
    this.residenceAddress,
    this.departmentId,
    this.departmentName,
    this.positionId,
    this.positionName,
    this.supervisorId,
    this.supervisorName,
    this.hireDate,
    this.confirmedAt,
    this.status,
    this.employmentType,
    this.workLocation,
    this.seatNo,
    this.attendanceGroup,
    this.officePhone,
    this.email,
    this.paperArchiveNo,
    this.idNumber,
    this.phone,
    this.bankAccount,
    this.bankBranch,
    this.baseSalary,
    this.perfSalary,
    this.socialInsuranceBase,
    this.socialInsuranceLocation,
    this.housingFundBase,
    this.allowanceStandard,
    this.contractType,
    this.contractStart,
    this.contractEnd,
    this.probationMonths,
    this.probationEndDate,
    this.renewCount,
    this.emergencyContacts = const [],
    this.history = const [],
  });

  final String id;
  final String code;
  final String? fullName;
  final String? gender;
  final String? idType;
  final String? birthDate;
  final String? ethnicity;
  final String? politicalStatus;
  final String? maritalStatus;
  final String? hujiAddress;
  final String? residenceAddress;
  final String? departmentId;
  final String? departmentName;
  final String? positionId;
  final String? positionName;
  final String? supervisorId;
  final String? supervisorName;
  final String? hireDate;
  final String? confirmedAt;
  final String? status;
  final String? employmentType;
  final String? workLocation;
  final String? seatNo;
  final String? attendanceGroup;
  final String? officePhone;
  final String? email;
  final String? paperArchiveNo;

  // 敏感（按角色脱敏）
  final String? idNumber;
  final String? phone;
  final String? bankAccount;
  final String? bankBranch;

  // 薪资（仅授权角色）
  final String? baseSalary;
  final String? perfSalary;
  final String? socialInsuranceBase;
  final String? socialInsuranceLocation;
  final String? housingFundBase;
  final String? allowanceStandard;

  // 合同
  final String? contractType;
  final String? contractStart;
  final String? contractEnd;
  final int? probationMonths;
  final String? probationEndDate;
  final int? renewCount;

  final List<EmergencyContactView> emergencyContacts;
  final List<EmploymentHistoryView> history;

  factory EmployeeProfile.fromJson(Map<String, dynamic> json) {
    final ec = json['emergencyContacts'] as List<dynamic>? ?? const [];
    final hist = json['history'] as List<dynamic>? ?? const [];
    return EmployeeProfile(
      id: json['id'] as String,
      code: json['code'] as String,
      fullName: json['fullName'] as String?,
      gender: json['gender'] as String?,
      idType: json['idType'] as String?,
      birthDate: json['birthDate'] as String?,
      ethnicity: json['ethnicity'] as String?,
      politicalStatus: json['politicalStatus'] as String?,
      maritalStatus: json['maritalStatus'] as String?,
      hujiAddress: json['hujiAddress'] as String?,
      residenceAddress: json['residenceAddress'] as String?,
      departmentId: json['departmentId'] as String?,
      departmentName: json['departmentName'] as String?,
      positionId: json['positionId'] as String?,
      positionName: json['positionName'] as String?,
      supervisorId: json['supervisorId'] as String?,
      supervisorName: json['supervisorName'] as String?,
      hireDate: json['hireDate'] as String?,
      confirmedAt: json['confirmedAt'] as String?,
      status: json['status'] as String?,
      employmentType: json['employmentType'] as String?,
      workLocation: json['workLocation'] as String?,
      seatNo: json['seatNo'] as String?,
      attendanceGroup: json['attendanceGroup'] as String?,
      officePhone: json['officePhone'] as String?,
      email: json['email'] as String?,
      paperArchiveNo: json['paperArchiveNo'] as String?,
      idNumber: json['idNumber'] as String?,
      phone: json['phone'] as String?,
      bankAccount: json['bankAccount'] as String?,
      bankBranch: json['bankBranch'] as String?,
      baseSalary: json['baseSalary'] as String?,
      perfSalary: json['perfSalary'] as String?,
      socialInsuranceBase: json['socialInsuranceBase'] as String?,
      socialInsuranceLocation: json['socialInsuranceLocation'] as String?,
      housingFundBase: json['housingFundBase'] as String?,
      allowanceStandard: json['allowanceStandard'] as String?,
      contractType: json['contractType'] as String?,
      contractStart: json['contractStart'] as String?,
      contractEnd: json['contractEnd'] as String?,
      probationMonths: json['probationMonths'] as int?,
      probationEndDate: json['probationEndDate'] as String?,
      renewCount: json['renewCount'] as int?,
      emergencyContacts: ec.map((e) => EmergencyContactView.fromJson(e as Map<String, dynamic>)).toList(),
      history: hist.map((e) => EmploymentHistoryView.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

/// 员工入职 payload（对应后端 OnboardingRequest，5 步向导聚合）。
class EmployeeOnboardingInput {
  EmployeeOnboardingInput({
    required this.profile,
    required this.employment,
    this.compensation,
    this.contract,
    this.emergencyContacts = const [],
    this.account = const AccountInput(),
  });

  final Map<String, dynamic> profile;
  final Map<String, dynamic> employment;
  final Map<String, dynamic>? compensation;
  final Map<String, dynamic>? contract;
  final List<Map<String, dynamic>> emergencyContacts;
  final AccountInput account;

  Map<String, dynamic> toJson() => {
        'profile': profile,
        'employment': employment,
        if (compensation != null) 'compensation': compensation,
        if (contract != null) 'contract': contract,
        'emergencyContacts': emergencyContacts,
        'account': account.toJson(),
      };
}

class AccountInput {
  const AccountInput({this.roles = const ['employee'], this.loginAccount});
  final List<String> roles;
  final String? loginAccount;

  Map<String, dynamic> toJson() => {
        'roles': roles,
        if (loginAccount != null) 'loginAccount': loginAccount,
      };
}
