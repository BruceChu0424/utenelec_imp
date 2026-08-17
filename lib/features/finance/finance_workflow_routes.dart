/// 财务订货审批工作流的前端深链。
///
/// 路由注册由 app_router 统一维护；本文件让 Hub、任务页和测试共享同一字符串，
/// 避免尚未注册 RouteName 时在多处散落路径。
abstract final class FinanceWorkflowRoutes {
  static const approvalTasks = '/finance/procurement-approvals';
  static const arrivalExceptionTasks =
      '/finance/procurement-arrival-exceptions';

  /// 销售订货单财务确认任务页（V294 闸门；后端通知 actionRoute 与此保持一致）。
  static const salesOrderConfirmations = '/finance/sales-order-confirmations';

  static String arrivalException(String id) =>
      '$arrivalExceptionTasks/${Uri.encodeComponent(id)}';
}
