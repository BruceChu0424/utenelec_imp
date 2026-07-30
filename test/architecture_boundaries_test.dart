import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Flutter feature 依赖图的棘轮测试。
///
/// 现有依赖先冻结为基线；重构可以删除边，但新增跨 feature 方向必须先经过
/// ADR-017 约定的架构评审。通用能力应优先移动到 shared/ 或 components/。
void main() {
  const approvedEdges = <String>{
    'admin->basic_data',
    'admin->department',
    'dashboard->hr_profile',
    'dashboard->production',
    'dashboard->purchase',
    'dashboard->visitor_approval',
    'department->employee',
    'employee->department',
    'employee->profile',
    'finance->basic_data',
    'finance->employee',
    'finance->report',
    'hr_profile->profile',
    'payroll->employee',
    'production->basic_data',
    'production->department',
    'production->employee',
    'production->report',
    'production->sales',
    'profile->employee',
    'purchase->basic_data',
    'purchase->employee',
    'purchase->production',
    'purchase->report',
    'report->basic_data',
    'sales->basic_data',
    'sales->employee',
    'sales->production',
    'sales->report',
    'security->visitor',
    'shell->dashboard',
    'shell->notice',
    'shell->profile',
    'shell->settings',
    'stock->basic_data',
    'subcontract->basic_data',
    'subcontract->employee',
    'subcontract->report',
    'visitor_approval->notice',
    'visitor_approval->visitor',
    'visitor->department',
    'visitor->settings',
    'warehouse->basic_data',
    'warehouse->report',
  };

  test('feature dependency graph does not grow', () {
    final libRoot = Directory('lib').absolute;
    final featuresRoot = Directory('lib/features').absolute;
    final featuresPrefix = _normalized(
      '${featuresRoot.path}${Platform.pathSeparator}',
    );
    final actualEdges = <String>{};
    final directive = RegExp(
      r'''^(?:import|export)\s+['"]([^'"]+)['"]''',
      multiLine: true,
    );

    for (final entity in featuresRoot.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final relativeSource = entity.absolute.path.substring(
        featuresRoot.path.length + 1,
      );
      final sourceFeature = relativeSource.split(Platform.pathSeparator).first;

      for (final match in directive.allMatches(entity.readAsStringSync())) {
        final importPath = match.group(1)!;
        final target = _resolveImport(entity, libRoot, importPath);
        if (target == null) {
          continue;
        }
        final targetPath = _normalized(target.absolute.path);
        if (!targetPath.startsWith(featuresPrefix)) {
          continue;
        }
        final relativeTarget = target.absolute.path.substring(
          featuresRoot.path.length + 1,
        );
        final targetFeature = relativeTarget
            .split(Platform.pathSeparator)
            .first;
        if (sourceFeature != targetFeature) {
          actualEdges.add('$sourceFeature->$targetFeature');
        }
      }
    }

    final unapproved = actualEdges.difference(approvedEdges).toList()..sort();
    expect(
      unapproved,
      isEmpty,
      reason:
          '检测到新的跨 feature 依赖方向。请改用 shared/components 或公开契约：'
          '\n${unapproved.join('\n')}',
    );
  });
}

File? _resolveImport(File source, Directory libRoot, String importPath) {
  if (importPath.startsWith('package:uten_imp/')) {
    final relative = importPath.substring('package:uten_imp/'.length);
    return File('${libRoot.path}${Platform.pathSeparator}$relative');
  }
  if (importPath.startsWith('.')) {
    return File.fromUri(source.parent.uri.resolve(importPath));
  }
  return null;
}

String _normalized(String path) =>
    Platform.isWindows ? path.toLowerCase() : path;
