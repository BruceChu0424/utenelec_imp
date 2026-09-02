import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Flutter feature 依赖图的棘轮测试。
///
/// 现有依赖先冻结为基线；重构可以删除边，但新增跨 feature 方向必须先经过
/// ADR-017 约定的架构评审。通用能力应优先移动到 shared/ 或 components/。
void main() {
  const baselineEdges = <String>{
    'admin->auth',
    'admin->department',
    // 2026-08-18：权限页「开通账号」弹窗选员工+展示员工凭据（V297 临时密码配套），
    // 账号天然挂员工，与后端 admin 枢纽同构。
    'admin->employee',
    'basic_data->department',
    'basic_data->employee',
    'dashboard->admin',
    'dashboard->finance',
    'dashboard->hr_task',
    'dashboard->notice',
    'dashboard->production',
    'dashboard->purchase',
    'dashboard->rd_task',
    'dashboard->sales',
    'dashboard->subcontract',
    'dashboard->visitor_approval',
    'dashboard->warehouse',
    'department->basic_data',
    'department->employee',
    'employee->department',
    'employee->profile',
    'expense->basic_data',
    'finance->basic_data',
    'finance->department',
    'finance->employee',
    'finance->report',
    'finance->warehouse',
    'hr_profile->profile',
    'hr_task->employee',
    'hr_task->notice',
    'notice->dashboard',
    'notice->department',
    // 2026-08-18：发布通知后静默刷新研发任务汇总（联动信号，与 dashboard->hr_task 同款）。
    'notice->hr_task',
    'operations_workbench->basic_data',
    'production->basic_data',
    'production->department',
    'production->employee',
    // 2026-08-29：待排产「一键转发研发」随 BOM 缺失口径下线（ADR-057），
    // production 不再依赖 rd_task。
    'production->report',
    'production->warehouse',
    'profile->department',
    'profile->employee',
    'purchase->basic_data',
    'purchase->department',
    'purchase->employee',
    'purchase->notice',
    'purchase->operations_workbench',
    'purchase->report',
    'purchase->warehouse',
    'rd_task->basic_data',
    'report->basic_data',
    'sales->basic_data',
    'sales->department',
    'sales->employee',
    'sales->notice',
    'sales->production',
    'sales->report',
    'security->visitor',
    'shell->dashboard',
    'shell->notice',
    'shell->profile',
    'shell->settings',
    'stock->basic_data',
    'subcontract->basic_data',
    'subcontract->department',
    'subcontract->employee',
    'subcontract->operations_workbench',
    'subcontract->report',
    'subcontract->warehouse',
    'visitor_approval->visitor',
    'visitor->department',
    'visitor->settings',
    'warehouse->basic_data',
    // 2026-08-19：仓库登记实际到货独立页（/warehouse/inbound/receipts/new）——
    // 仓库代采购/委外执行收货登记，复用两类收货仓储与配置（与后端
    // WarehouseInboundController 注入 Purchase/SubcontractReceiptService 同构）；
    // 收货人/采购员选择器复用员工与部门检索（与 purchase->employee/department 同款）。
    'warehouse->department',
    'warehouse->employee',
    'warehouse->purchase',
    'warehouse->subcontract',
    'warehouse->report',
    'warehouse->stock',
    // 2026-08-19：品质任务中心「待检处置」角标读取仓储侧 IQC 待检计数 provider
    //（procurementInspectionPendingCountProvider），与 dashboard->warehouse 同源。
    'quality->warehouse',
    // 2026-09-01：财务枢纽角标聚合 IQC 驳回待办（同 dashboard->* 聚合同款）。
    'finance->procurement_iqc_rejection',
    // 2026-09-01：销售发货财务审核页（V443 surface）复用销售发货任务工作台——
    // 财务审核即销售发货的财务视图，工作台暂留 sales，待组件化后升 shared。
    'finance->sales',
    // 2026-09-01：采购 IQC 驳回列表复用主档表格壳。master_data_table_view 目前
    // 落在 basic_data/widgets（76 文件引用），专业化阶段将升至 lib/components，
    // 届时本边与 quality->basic_data 一并收紧删除。
    'procurement_iqc_rejection->basic_data',
    // 2026-09-01：品质记录/待处置/FQC 队列复用主档表格壳与 facet 模型（同上，
    // 组件升位后删除）。
    'quality->basic_data',
    // 2026-09-01：委外前置准备页（V447）读取生产物料分析模型与仓储——前置准备
    // 本质是生产分析的一个视图，与后端 SubcontractPreparation 依赖同构。
    'subcontract->production',
  };

  test('feature dependency graph does not grow', () {
    final libRoot = Directory('lib').absolute;
    final featuresRoot = Directory('lib/features').absolute;
    final actualEdges = <String>{};
    final directive = RegExp(
      r'''^(?:import|export)\s+['"]([^'"]+)['"]''',
      multiLine: true,
    );

    for (final entity in featuresRoot.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final sourceFeature = _featureFromPath(
        entity.absolute.path,
        featuresRoot.path,
      );
      if (sourceFeature == null) {
        continue;
      }

      for (final match in directive.allMatches(entity.readAsStringSync())) {
        final importPath = match.group(1)!;
        final target = _resolveImport(entity, libRoot, importPath);
        if (target == null) {
          continue;
        }
        final targetFeature = _featureFromPath(
          target.absolute.path,
          featuresRoot.path,
        );
        if (targetFeature == null) {
          continue;
        }
        if (sourceFeature != targetFeature) {
          actualEdges.add('$sourceFeature->$targetFeature');
        }
      }
    }

    final unapproved = actualEdges.difference(baselineEdges).toList()..sort();
    expect(
      unapproved,
      isEmpty,
      reason:
          '检测到新的跨 feature 依赖方向。请改用 shared/components 或公开契约：'
          '\n${unapproved.join('\n')}',
    );

    final staleBaseline = baselineEdges.difference(actualEdges).toList()
      ..sort();
    expect(
      staleBaseline,
      isEmpty,
      reason:
          '检测到已经消失的跨 feature 依赖方向。请同步收紧基线：'
          '\n${staleBaseline.join('\n')}',
    );
  });

  test('feature path extraction handles mixed separators and boundaries', () {
    const root = r'C:\repo\lib\features';

    expect(
      _featureFromPath(r'C:\repo\lib\features/admin/a.dart', root),
      'admin',
    );
    expect(
      _featureFromPath(r'C:\repo\lib\features\admin\a.dart', root),
      'admin',
    );
    expect(
      _featureFromPath(r'C:\repo\lib\features_extra\admin\a.dart', root),
      isNull,
    );
  });

  test('package feature import resolves through the lib URI', () {
    final libRoot = Directory('lib').absolute;
    final featuresRoot = Directory('lib/features').absolute;
    final source = File.fromUri(
      featuresRoot.uri.resolve('admin/models/impersonation.dart'),
    );
    final target = _resolveImport(
      source,
      libRoot,
      'package:uten_imp/features/auth/models/auth_session.dart',
    );

    expect(target, isNotNull);
    expect(_featureFromPath(target!.absolute.path, featuresRoot.path), 'auth');
  });
}

File? _resolveImport(File source, Directory libRoot, String importPath) {
  if (importPath.startsWith('package:uten_imp/')) {
    final relative = importPath.substring('package:uten_imp/'.length);
    return File.fromUri(libRoot.uri.resolve(relative));
  }
  if (importPath.startsWith('.')) {
    return File.fromUri(source.parent.uri.resolve(importPath));
  }
  return null;
}

String _normalized(String path) {
  final withForwardSlashes = path.replaceAll('\\', '/');
  return Platform.isWindows
      ? withForwardSlashes.toLowerCase()
      : withForwardSlashes;
}

String? _featureFromPath(String candidatePath, String featuresRootPath) {
  final root = _normalized(featuresRootPath);
  final prefix = root.endsWith('/') ? root : '$root/';
  final candidate = _normalized(candidatePath);
  if (!candidate.startsWith(prefix)) {
    return null;
  }
  final relative = candidate.substring(prefix.length);
  if (relative.isEmpty) {
    return null;
  }
  return relative.split('/').first;
}
