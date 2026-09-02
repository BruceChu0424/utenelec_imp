// 员工 API 模型（对应后端 EmployeeListItem / EmployeeDetail / 入职 payload）。

import '../../../shared/attachments/attachment.dart';

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
    this.positionLevel,
    this.departmentManager = false,
    this.leaderRank = 3,
    this.departmentId,
    this.matchedPlates,
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
  final String? positionLevel;
  final bool departmentManager;
  final int leaderRank;
  final String? departmentId; // 所属部门 id（部门管理页"搜员工定位部门"用）
  final String? matchedPlates; // 搜索命中车牌（「、」分隔）—— ADR-021 按车牌找人

  factory EmployeeSummary.fromJson(Map<String, dynamic> json) =>
      EmployeeSummary(
        id: json['id'] as String,
        code: json['code'] as String,
        fullName: json['fullName'] as String,
        gender: json['gender'] as String?,
        departmentName: json['departmentName'] as String?,
        positionName: json['positionName'] as String?,
        status: json['status'] as String?,
        employmentType: json['employmentType'] as String?,
        hireDate: json['hireDate'] as String?,
        positionLevel: json['positionLevel'] as String?,
        departmentManager: json['departmentManager'] as bool? ?? false,
        leaderRank: (json['leaderRank'] as num?)?.toInt() ?? 3,
        departmentId: json['departmentId'] as String?,
        matchedPlates: json['matchedPlates'] as String?,
      );
}

class EmergencyContactView {
  const EmergencyContactView({
    this.id,
    this.name,
    this.phone,
    this.relationship,
  });
  final String? id;
  final String? name;
  final String? phone; // 已按角色脱敏
  final String? relationship;

  factory EmergencyContactView.fromJson(Map<String, dynamic> json) =>
      EmergencyContactView(
        id: json['id'] as String?,
        name: json['name'] as String?,
        phone: json['phone'] as String?,
        relationship: json['relationship'] as String?,
      );
}

/// 员工车辆（ADR-021；全部非必填，车牌明文用于「按车牌找人」）。
class EmployeeVehicleView {
  const EmployeeVehicleView({
    this.id,
    this.plateNo,
    this.vehicleType,
    this.brandModel,
    this.color,
    this.remark,
  });
  final String? id;
  final String? plateNo;
  final String? vehicleType;
  final String? brandModel;
  final String? color;
  final String? remark;

  factory EmployeeVehicleView.fromJson(Map<String, dynamic> json) =>
      EmployeeVehicleView(
        id: json['id'] as String?,
        plateNo: json['plateNo'] as String?,
        vehicleType: json['vehicleType'] as String?,
        brandModel: json['brandModel'] as String?,
        color: json['color'] as String?,
        remark: json['remark'] as String?,
      );

  Map<String, dynamic> toInput() => {
    'plateNo': plateNo,
    if (vehicleType != null) 'vehicleType': vehicleType,
    if (brandModel != null) 'brandModel': brandModel,
    if (color != null) 'color': color,
    if (remark != null) 'remark': remark,
  };
}

/// 员工备用手机号（已按权限脱敏；本人自助为明文）。
class EmployeePhoneView {
  const EmployeePhoneView({this.id, this.label, this.phone});
  final String? id;
  final String? label;
  final String? phone;

  factory EmployeePhoneView.fromJson(Map<String, dynamic> json) =>
      EmployeePhoneView(
        id: json['id'] as String?,
        label: json['label'] as String?,
        phone: json['phone'] as String?,
      );

  Map<String, dynamic> toInput() => {
    if (label != null) 'label': label,
    'phone': phone,
  };
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

  factory EmploymentHistoryView.fromJson(Map<String, dynamic> json) =>
      EmploymentHistoryView(
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
    this.positionLevel,
    this.departmentManager = false,
    this.leaderRank = 3,
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
    this.accountStatus,
    this.emergencyContacts = const [],
    this.history = const [],
    this.vehicles = const [],
    this.phones = const [],
    this.attachments = const [],
    this.contracts = const [],
    this.avatarStorageKey,
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
  final String? positionLevel;
  final bool departmentManager;
  final int leaderRank;
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

  // 登录账号状态（active/locked/disabled；null = 未开通账号）
  final String? accountStatus;

  final List<EmergencyContactView> emergencyContacts;
  final List<EmploymentHistoryView> history;
  final List<EmployeeVehicleView> vehicles; // ADR-021
  final List<EmployeePhoneView> phones; // 备用手机号（按权限脱敏）

  /// 档案文件（合同/证件/学历/照片/其他，CLEAN 附件）。
  final List<Attachment> attachments;

  /// 合同时间线（含到期天数/预警）。
  final List<EmployeeContractView> contracts;

  /// 头像 storage_key（为空用首字头像）。
  final String? avatarStorageKey;

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
      positionLevel: json['positionLevel'] as String?,
      departmentManager: json['departmentManager'] as bool? ?? false,
      leaderRank: (json['leaderRank'] as num?)?.toInt() ?? 3,
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
      accountStatus: json['accountStatus'] as String?,
      emergencyContacts: ec
          .map((e) => EmergencyContactView.fromJson(e as Map<String, dynamic>))
          .toList(),
      history: hist
          .map((e) => EmploymentHistoryView.fromJson(e as Map<String, dynamic>))
          .toList(),
      vehicles: (json['vehicles'] as List<dynamic>? ?? const [])
          .map((e) => EmployeeVehicleView.fromJson(e as Map<String, dynamic>))
          .toList(),
      phones: (json['phones'] as List<dynamic>? ?? const [])
          .map((e) => EmployeePhoneView.fromJson(e as Map<String, dynamic>))
          .toList(),
      attachments: (json['attachments'] as List<dynamic>? ?? const [])
          .map((e) => Attachment.fromJson(e as Map<String, dynamic>))
          .toList(),
      contracts: (json['contracts'] as List<dynamic>? ?? const [])
          .map((e) => EmployeeContractView.fromJson(e as Map<String, dynamic>))
          .toList(),
      avatarStorageKey: json['avatarStorageKey'] as String?,
    );
  }
}

/// 劳动合同（时间线一项）。daysToExpiry 为 null 表示无固定期限。
class EmployeeContractView {
  const EmployeeContractView({
    required this.id,
    required this.contractType,
    required this.startDate,
    this.endDate,
    this.probationMonths,
    required this.signOrder,
    this.daysToExpiry,
    required this.expiring,
    required this.ended,
  });

  final String id;
  final String contractType;
  final String? startDate;
  final String? endDate;
  final int? probationMonths;
  final int signOrder;
  final int? daysToExpiry;
  final bool expiring;
  final bool ended;

  factory EmployeeContractView.fromJson(Map<String, dynamic> json) {
    return EmployeeContractView(
      id: json['id'] as String,
      contractType: json['contractType'] as String,
      startDate: json['startDate'] as String?,
      endDate: json['endDate'] as String?,
      probationMonths: json['probationMonths'] as int?,
      signOrder: (json['signOrder'] as num?)?.toInt() ?? 1,
      daysToExpiry: json['daysToExpiry'] as int?,
      expiring: json['expiring'] as bool? ?? false,
      ended: json['ended'] as bool? ?? false,
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

/// 兼职部门归属（V459）：员工在主部门之外兼任的部门，权限合成并入兼职部门链。
class EmployeeSecondaryDepartment {
  const EmployeeSecondaryDepartment({
    required this.departmentId,
    required this.departmentName,
    this.startedOn,
    this.note,
  });

  factory EmployeeSecondaryDepartment.fromJson(Map<String, dynamic> json) {
    return EmployeeSecondaryDepartment(
      departmentId: json['departmentId'] as String,
      departmentName: json['departmentName'] as String? ?? '',
      startedOn: json['startedOn'] as String?,
      note: json['note'] as String?,
    );
  }

  final String departmentId;
  final String departmentName;
  final String? startedOn;
  final String? note;
}
