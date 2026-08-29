// 「一键全部授权」永不批量授予的高危/个人-only 权限码集合。
//
// 此集合同时包含后端 individual-only 权限，以及其他不应被个人「全部授权」
// 顺带授予的高风险业务权限：审计调查、授权与账号管理、账户/库存余额调整、
// 资产生命周期(审批/过账/处置/导出/期间)、审批负责人配置、急单优先级与
// 稀缺让单、原下单人专属的供应商退回。
// CROSS 可按部门或逐条个人显式配置，但不得被个人「全部授权」顺带授予。
// 批量授予会破坏职责分离，故「全部授权」按钮把它们排除在外。
//
// 与后端 INDIVIDUAL_ONLY_PERMISSION_CODES（audit_log:* + account:balance:adjust，见
// DepartmentPermissionAdminService）对齐并扩展到更广的高危面。
import '../../shared/auth/permissions.dart';

/// 「一键全部授权」排除的权限码。见文件头说明。
const Set<String> kAuthorizeAllExcluded = {
  Perm.auditLogView,
  Perm.auditLogExport,
  Perm.authorizationManage,
  'user:manage',
  Perm.accountBalanceAdjust,
  Perm.stockBalanceAdjust,
  Perm.financeAssetApprove,
  Perm.financeAssetPost,
  Perm.financeAssetDispose,
  Perm.financeAssetExport,
  Perm.financeAssetPeriodManage,
  Perm.salesOrderPriority,
  Perm.salesOrderReallocate,
  Perm.productionMaterialAnalysisCrossReallocate,
  Perm.supplierReturnTaskView,
  Perm.supplierReturnTaskComplete,
};
