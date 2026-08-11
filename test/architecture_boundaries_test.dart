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
    'expense->storage',
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
    'operations_workbench->basic_data',
    'production->basic_data',
    'production->department',
    'production->employee',
    'production->rd_task',
    'production->report',
    'production->sales',
    'production->warehouse',
    'profile->department',
    'profile->employee',
    'purchase->basic_data',
    'purchase->department',
    'purchase->employee',
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
    'visitor_approval->notice',
    'visitor_approval->visitor',
    'visitor->department',
    'visitor->settings',
    'warehouse->basic_data',
    'warehouse->report',
    'warehouse->stock',
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
