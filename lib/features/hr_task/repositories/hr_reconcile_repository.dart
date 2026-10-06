// 员工资料核对更正数据接入（后端 /api/org/employee-reconcile，ADR-160）。
//
// 路径直接落在仓库里（本期未进 ApiEndpoints：核对域只有这一组端点，
// 页面/仓库同批落地，避免与他域常量表交叉改动）。apply 是长事务，
// 走 postLongRunning（接收超时 3 分钟）；服务端先回 403 REAUTH_REQUIRED
// 再放行由网络层 StepUpInterceptor 弹统一密码框并重放，仓库不感知。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/hr_reconcile_plan.dart';

/// 核对计划基础路径（ApiClient 基址已含 /api 前缀）。
const String _base = '/org/employee-reconcile';

/// apply 长事务接收超时：逐人执行 changeIdentity，人数多时显著超过全局 45s。
const Duration _applyReceiveTimeout = Duration(minutes: 3);

class HrReconcileRepository {
  const HrReconcileRepository(this._api);

  final ApiClient _api;

  /// 生成「证件修复」核对计划：每人一行（旧证件号 + 建议/候选/需人工）。
  Future<HrReconcilePlan> createIdRepairPlan(List<String> employeeIds) async {
    final json = await _api.post(
      '$_base/plans/id-repair',
      body: {'employeeIds': employeeIds},
    );
    return HrReconcilePlan.fromJson(json);
  }

  /// 读计划（核对记录回看 / apply 后重取渲染结果列）。
  Future<HrReconcilePlan> getPlan(String id) async {
    final json = await _api.get('$_base/plans/$id');
    return HrReconcilePlan.fromJson(json);
  }

  /// 核对记录首页（顶栏「核对记录」弹层）。
  Future<HrReconcilePlanSummaryPage> listPlans({
    int page = 1,
    int size = 50,
  }) async {
    final json = await _api.get(
      '$_base/plans',
      query: {'page': page, 'size': size},
    );
    return HrReconcilePlanSummaryPage.fromJson(json);
  }

  /// 执行更正（长事务；403 REAUTH_REQUIRED 由拦截器自动弹密码框重放）。
  Future<HrReconcileApplyResult> apply(
    String planId, {
    required int planVersion,
    required String requestId,
    required List<HrReconcileApplyRow> rows,
  }) async {
    final json = await _api.postLongRunning(
      '$_base/plans/$planId/apply',
      body: HrReconcileApplyRequest(
        planVersion: planVersion,
        requestId: requestId,
        rows: rows,
      ).toJson(),
      receiveTimeout: _applyReceiveTimeout,
    );
    return HrReconcileApplyResult.fromJson(json);
  }

  /// 放弃计划（本期页面不放入口，留作契约对齐）。
  Future<void> discard(String planId) =>
      _api.post('$_base/plans/$planId/discard');
}

final hrReconcileRepositoryProvider = Provider<HrReconcileRepository>(
  (ref) => HrReconcileRepository(ref.watch(apiClientProvider)),
);
