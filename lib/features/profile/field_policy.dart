// 字段策略：与后端 ProfileFieldPolicy 对齐。
//
// 三档：
//   * directEdit     → 提交即生效
//   * requiresReview → 生成申请，HR 审核通过后合并
//   * hrOnly         → 员工页面只读，"请找 HR"提示
//
// 调整字段策略只改本文件。前端表单渲染、提交入口可见性、按钮徽章
// 都从这里取单一来源。

import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/profile/models/profile_change_request.dart';

abstract final class ProfileFieldPolicy {
  /// 字段代码常量（与后端 ProfileFieldPolicy.Field 一一对应）。
  static const fullName = 'fullName';
  static const gender = 'gender';
  static const birthDate = 'birthDate';
  static const ethnicity = 'ethnicity';
  static const politicalStatus = 'politicalStatus';
  static const maritalStatus = 'maritalStatus';
  static const hujiAddress = 'hujiAddress';
  static const residenceAddress = 'residenceAddress';
  static const phone = 'phone';
  static const officePhone = 'officePhone';
  static const email = 'email';
  static const seatNo = 'seatNo';
  static const workLocation = 'workLocation';
  // 紧急联系人：emergencyContact.{idx}.{name|phone|relationship}
  static const emergencyContactPrefix = 'emergencyContact.';

  // ----- 字段定义（i18n key + 策略 + 分组） -----

  static const List<ProfileFieldDef> selfEditableFields = [
    // 直改
    ProfileFieldDef(
      code: ethnicity,
      labelKey: 'profileFieldEthnicity',
      kind: FieldPolicyKind.directEdit,
      group: 'identity',
    ),
    ProfileFieldDef(
      code: politicalStatus,
      labelKey: 'profileFieldPoliticalStatus',
      kind: FieldPolicyKind.directEdit,
      group: 'identity',
    ),
    ProfileFieldDef(
      code: maritalStatus,
      labelKey: 'profileFieldMaritalStatus',
      kind: FieldPolicyKind.directEdit,
      group: 'identity',
    ),
    ProfileFieldDef(
      code: residenceAddress,
      labelKey: 'profileFieldResidenceAddress',
      kind: FieldPolicyKind.directEdit,
      group: 'address',
    ),
    ProfileFieldDef(
      code: officePhone,
      labelKey: 'profileFieldOfficePhone',
      kind: FieldPolicyKind.directEdit,
      group: 'contact',
    ),
    ProfileFieldDef(
      code: email,
      labelKey: 'profileFieldEmail',
      kind: FieldPolicyKind.directEdit,
      group: 'contact',
    ),
    ProfileFieldDef(
      code: seatNo,
      labelKey: 'profileFieldSeatNo',
      kind: FieldPolicyKind.directEdit,
      group: 'address',
    ),
    // 需审核
    ProfileFieldDef(
      code: fullName,
      labelKey: 'profileChangeFieldFullName',
      kind: FieldPolicyKind.requiresReview,
      group: 'identity',
    ),
    ProfileFieldDef(
      code: hujiAddress,
      labelKey: 'profileFieldHujiAddress',
      kind: FieldPolicyKind.requiresReview,
      group: 'address',
    ),
    ProfileFieldDef(
      code: phone,
      labelKey: 'profileFieldPhone',
      kind: FieldPolicyKind.requiresReview,
      group: 'contact',
    ),
    // 紧急联系人：使用通配前缀，渲染时按 idx 展开
    ProfileFieldDef(
      code: '${emergencyContactPrefix}0.name',
      labelKey: 'profileChangeFieldEmergencyName',
      kind: FieldPolicyKind.requiresReview,
      group: 'emergency',
    ),
    ProfileFieldDef(
      code: '${emergencyContactPrefix}0.phone',
      labelKey: 'profileChangeFieldEmergencyPhone',
      kind: FieldPolicyKind.requiresReview,
      group: 'emergency',
    ),
    ProfileFieldDef(
      code: '${emergencyContactPrefix}0.relationship',
      labelKey: 'profileChangeFieldEmergencyRelationship',
      kind: FieldPolicyKind.requiresReview,
      group: 'emergency',
    ),
  ];

  /// HR 专属（员工页只读，"请联系人事"）。
  static const List<ProfileFieldDef> hrOnlyFields = [
    ProfileFieldDef(
      code: gender,
      labelKey: 'profileFieldGender',
      kind: FieldPolicyKind.hrOnly,
      group: 'identity',
    ),
    ProfileFieldDef(
      code: birthDate,
      labelKey: 'profileFieldBirthDate',
      kind: FieldPolicyKind.hrOnly,
      group: 'identity',
    ),
    ProfileFieldDef(
      code: workLocation,
      labelKey: 'profileFieldWorkLocation',
      kind: FieldPolicyKind.hrOnly,
      group: 'address',
    ),
  ];

  static ProfileFieldDef? findByCode(String code) {
    for (final f in selfEditableFields) {
      if (f.code == code) return f;
    }
    for (final f in hrOnlyFields) {
      if (f.code == code) return f;
    }
    return null;
  }

  static bool isDirectEdit(String code) => selfEditableFields.any(
    (f) => f.code == code && f.kind == FieldPolicyKind.directEdit,
  );

  static bool isRequiresReview(String code) => selfEditableFields.any(
    (f) => f.code == code && f.kind == FieldPolicyKind.requiresReview,
  );

  static bool isHrOnly(String code) => hrOnlyFields.any((f) => f.code == code);

  /// 当前用户至少有一个可编辑字段（不论直改还是需审核）。
  static bool hasAnyEditable() => selfEditableFields.isNotEmpty;

  /// 把字段 code（及可能脏的存储 label）解析成可展示的本地化字段名。
  ///
  /// 后端 [ProfileChangeRequest.fieldLabel] 历史上可能被存成 i18n key（如
  /// `profileChangeFieldFullName`）或裸机器码（如 `emergencyContact.1.phone`），
  /// 直接展示会把系统字段结构/i18n 体系暴露给最终用户（通知正文等）。这里统一回落
  /// 到本地化中文：1) [storedLabel] 是正常显示名（非 key）→ 直接用；2) 否则按 code
  /// 查本地化中文；3) 查不到才回落到 storedLabel/code。
  static String labelOf(
    AppLocalizations l10n,
    String code, {
    String? storedLabel,
  }) {
    final label = storedLabel ?? '';
    if (label.isNotEmpty && !_looksLikeKey(label)) return label;
    switch (code) {
      case fullName:
        return l10n.profileChangeFieldFullName;
      case hujiAddress:
        return l10n.profileFieldHujiAddress;
      case phone:
        return l10n.profileChangeFieldPhone;
      case ethnicity:
        return l10n.profileFieldEthnicity;
      case politicalStatus:
        return l10n.profileFieldPoliticalStatus;
      case maritalStatus:
        return l10n.profileFieldMaritalStatus;
      case residenceAddress:
        return l10n.profileFieldResidenceAddress;
      case officePhone:
        return l10n.profileFieldOfficePhone;
      case email:
        return l10n.profileFieldEmail;
      case seatNo:
        return l10n.profileFieldSeatNo;
      case gender:
        return l10n.profileFieldGender;
      case birthDate:
        return l10n.profileFieldBirthDate;
      case workLocation:
        return l10n.profileFieldWorkLocation;
    }
    if (code.startsWith(emergencyContactPrefix)) {
      final tail = code.substring(emergencyContactPrefix.length);
      final dot = tail.indexOf('.');
      final sub = dot > 0 ? tail.substring(dot + 1) : tail;
      return switch (sub) {
        'name' => l10n.profileChangeFieldEmergencyName,
        'phone' => l10n.profileChangeFieldEmergencyPhone,
        'relationship' => l10n.profileChangeFieldEmergencyRelationship,
        _ => label.isNotEmpty ? label : code,
      };
    }
    return label.isNotEmpty ? label : code;
  }

  /// 字段标签像不像 i18n key / 机器码（纯英文 camelCase）。
  static bool _looksLikeKey(String s) =>
      RegExp(r'^[a-z][a-zA-Z0-9]+$').hasMatch(s);
}
