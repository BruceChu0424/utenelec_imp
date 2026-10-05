// 证件类型代码表：入职页与修改证件弹窗共用。
// 代码值就是后端存储值(EmployeeIdentityCheck.ID_TYPES)，显示文字走多语言。
import '../../../core/l10n/gen/app_localizations.dart';

/// 身份证：唯一有校验规则(GB11643)的证件类型。
const employeeIdTypeIdCard = '身份证';

/// 后端允许的全部证件类型(顺序即下拉顺序)。
const employeeIdTypeCodes = [employeeIdTypeIdCard, '护照', '港澳台通行证', '其他'];

String employeeIdTypeLabel(AppLocalizations l10n, String code) =>
    switch (code) {
      employeeIdTypeIdCard => l10n.idTypeIdCard,
      '护照' => l10n.idTypePassport,
      '港澳台通行证' => l10n.idTypeHmtPermit,
      '其他' => l10n.idTypeOther,
      _ => code,
    };
