// 权限点常量（与后端 permissions 表 code 对齐）+ 当前用户权限/角色 Provider。
// 文档：docs/05-架构/全局机制.md §1
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/role.dart';
import '../providers/session_provider.dart';

abstract final class Perm {
  static const employeeView = 'employee:view';
  static const employeeCreate = 'employee:create';
  static const employeeEdit = 'employee:edit';
  static const employeeDelete = 'employee:delete';
  static const departmentView = 'department:view';
  static const departmentEdit = 'department:edit';
  static const userManage = 'user:manage';
  static const payrollViewSelf = 'payroll:view:self';
  static const payrollViewAll = 'payroll:view:all';
  static const payrollGenerate = 'payroll:generate';
  static const payrollReview = 'payroll:review';
  static const expenseApprove = 'expense:approve';
  static const visitorView = 'visitor:view';
  static const visitorApprove = 'visitor:approve';
  static const visitorHostConfirm = 'visitor:host-confirm';
  static const visitorCheckIn = 'visitor:check-in';

  // 个人信息自助修改（Phase 6）
  static const profileEditSelf = 'profile:edit:self';
  static const profileReview = 'profile:review';
  /// 查看员工薪资/补偿字段（HR/finance/admin）；
  /// 渐进替代 DataAccessPolicy 里按角色名硬编码的判断。
  static const employeeCompensationView = 'employee:compensation:view';

  /// 决策支持（经营 Dashboard/多维分析/异常告警）。默认仅 manager/admin，
  /// 其他人由超管在权限管理页显式授予（V25，与 viewcontext:scoped 解耦）。
  static const analyticsView = 'analytics:view';

  // ===== 采购管理（PMC 运营部；后端 V44 细粒度种子化）=====
  /// 采购申请单
  static const purchaseRequestView = 'purchase_request:view';
  static const purchaseRequestEdit = 'purchase_request:edit';
  /// 采购订货单
  static const purchaseOrderView = 'purchase_order:view';
  static const purchaseOrderEdit = 'purchase_order:edit';
  /// 采购收货单
  static const purchaseReceiptView = 'purchase_receipt:view';
  static const purchaseReceiptEdit = 'purchase_receipt:edit';
  /// 采购退货单
  static const purchaseReturnView = 'purchase_return:view';
  static const purchaseReturnEdit = 'purchase_return:edit';
  /// 采购报表（本轮未接入页面，权限点已种子化）
  static const purchaseReportView = 'purchase_report:view';

  // ===== 财税部新模块（后端已种子化；页面未接入前由占位页承接）=====
  /// 采购管理（旧粗粒度占位，已被上方细分 purchase_* 取代；保留常量以免破坏旧引用）
  static const purchaseView = 'purchase:view';
  static const purchaseEdit = 'purchase:edit';

  /// 客户资料（三级数据范围：本人/部门/全部，任一即可看入口）
  static const customerViewSelf = 'customer:view:self';
  static const customerViewDepartment = 'customer:view:department';
  static const customerViewAll = 'customer:view:all';

  /// 供应商资料
  static const supplierView = 'supplier:view';
  static const supplierEdit = 'supplier:edit';

  /// 账户资料
  static const accountView = 'account:view';
  static const accountEdit = 'account:edit';

  /// 基础资料（我的资料页）
  static const basicinfoView = 'basicinfo:view';

  /// 货品资料分类（基础资料）
  static const materialCategoryView = 'material_category:view';
  static const materialCategoryEdit = 'material_category:edit';

  /// 货品主档（基础资料；V32 已将 goods:view 授予全部部门）
  static const goodsView = 'goods:view';
  static const goodsEdit = 'goods:edit';

  /// 模具资料分类（基础资料）
  static const mouldCategoryView = 'mould_category:view';
  static const mouldCategoryEdit = 'mould_category:edit';

  /// 模具主档（基础资料；V34 已将 mould:view 授予全部部门）
  static const mouldView = 'mould:view';
  static const mouldEdit = 'mould:edit';

  /// 客户资料分类（基础资料）
  static const clientCategoryView = 'client_category:view';
  static const clientCategoryEdit = 'client_category:edit';

  /// 客户主档（基础资料；V36 已将 client:view 授予全部部门）
  static const clientView = 'client:view';
  static const clientEdit = 'client:edit';

  /// 供应商资料分类（基础资料）
  static const supplierCategoryView = 'supplier_category:view';
  static const supplierCategoryEdit = 'supplier_category:edit';

  /// 颜色主档（基础资料；扁平结构，无分类树）
  static const colorView = 'color:view';
  static const colorEdit = 'color:edit';

  /// 基本单位主档（基础资料；扁平结构，无分类树）
  static const unitView = 'unit:view';
  static const unitEdit = 'unit:edit';

  /// 币种主档（基础资料；扁平结构，V42 种子化，view 全员 / edit 归 PMC）
  static const currencyView = 'currency:view';
  static const currencyEdit = 'currency:edit';

  /// 仓库主档（基础资料；扁平结构，V43 种子化，view 全员 / edit 归 PMC）
  static const warehouseView = 'warehouse:view';
  static const warehouseEdit = 'warehouse:edit';

  /// 库存查看（V45 种子化，全员；本轮采购审核联动库存，库存页未接入）
  static const stockView = 'stock:view';

  // 注：supplierView/supplierEdit（'supplier:view'/'supplier:edit'）见上方财税部段——
  // 后端 V38 以「主数据」category 种子化同一 code，基础资料与财税业务视图共用，故不重复定义。
}

/// 当前用户的功能权限集合。
///
/// 超级管理员（[UserProfile.superAdmin] == true）后端已经把全量 permissions 推过来，
/// 因此这里的 Set 已包含所有权限点。如果未来后端没推全，前端也会再 union 一个
/// "所有已知 Perm" 兜底——但主路径以后端为准。
final currentPermissionsProvider = Provider<Set<String>>((ref) {
  final user = ref.watch(sessionProvider).user;
  if (user == null) return const <String>{};
  if (user.superAdmin) {
    // 兜底：union 所有已知 Perm 常量。即便后端漏推某个新增权限也能 work。
    return <String>{
      Perm.employeeView,
      Perm.employeeCreate,
      Perm.employeeEdit,
      Perm.employeeDelete,
      Perm.departmentView,
      Perm.departmentEdit,
      Perm.userManage,
      Perm.payrollViewSelf,
      Perm.payrollViewAll,
      Perm.payrollGenerate,
      Perm.payrollReview,
      Perm.expenseApprove,
      Perm.visitorView,
      Perm.visitorApprove,
      Perm.visitorHostConfirm,
      Perm.visitorCheckIn,
      Perm.profileEditSelf,
      Perm.profileReview,
      Perm.employeeCompensationView,
      Perm.analyticsView,
      // 财税部新模块（超管兜底，后端漏推也能 work）
      Perm.purchaseView,
      Perm.purchaseEdit,
      // 采购管理细分（V44 种子化）
      Perm.purchaseRequestView,
      Perm.purchaseRequestEdit,
      Perm.purchaseOrderView,
      Perm.purchaseOrderEdit,
      Perm.purchaseReceiptView,
      Perm.purchaseReceiptEdit,
      Perm.purchaseReturnView,
      Perm.purchaseReturnEdit,
      Perm.purchaseReportView,
      Perm.currencyView,
      Perm.currencyEdit,
      Perm.warehouseView,
      Perm.warehouseEdit,
      Perm.stockView,
      Perm.customerViewSelf,
      Perm.customerViewDepartment,
      Perm.customerViewAll,
      Perm.supplierView,
      Perm.supplierEdit,
      Perm.accountView,
      Perm.accountEdit,
      Perm.basicinfoView,
      Perm.materialCategoryView,
      Perm.materialCategoryEdit,
      Perm.goodsView,
      Perm.goodsEdit,
      Perm.mouldCategoryView,
      Perm.mouldCategoryEdit,
      Perm.mouldView,
      Perm.mouldEdit,
      Perm.clientCategoryView,
      Perm.clientCategoryEdit,
      Perm.clientView,
      Perm.clientEdit,
      Perm.supplierCategoryView,
      Perm.supplierCategoryEdit,
      Perm.colorView,
      Perm.colorEdit,
      Perm.unitView,
      Perm.unitEdit,
      ...user.permissions,
    };
  }
  return user.permissions.toSet();
});

/// 当前用户是否为超级管理员（专一字段，便于 UI 短路判定）。
final isSuperAdminProvider = Provider<bool>((ref) {
  final user = ref.watch(sessionProvider).user;
  return user?.superAdmin ?? false;
});

/// 当前用户的角色名集合（如 {'hr','manager'}）。
final currentRolesProvider = Provider<Set<String>>((ref) {
  final user = ref.watch(sessionProvider).user;
  if (user == null) return const <String>{};
  return user.roles.map((Role r) => r.name).toSet();
});

/// 通用权限判定快捷函数。super admin 一律短路放行，其他按权限字符串匹配。
bool hasPerm(Ref ref, String code) {
  if (ref.read(isSuperAdminProvider)) return true;
  return ref.read(currentPermissionsProvider).contains(code);
}

/// 仅判断当前用户角色——不引入权限集。
bool hasRole(Ref ref, String code) {
  return ref.read(currentRolesProvider).contains(code);
}
