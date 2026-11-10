import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_zh.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/models/production_workshop_task_stage.dart';
import 'package:uten_imp/features/production/models/production_flow_stage.dart';
import 'package:uten_imp/features/production/widgets/production_flow_stage_cell.dart';
import 'package:uten_imp/components/data_display/uten_status_badge.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              'server/src/test/resources/contracts/workshop-task-stage-v1.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final l10n = AppLocalizationsZh();
  test('partial issue production uses its own existing violet status tier', () {
    final partial = ProductionExecutionWorkbenchSegment.fromJson({
      'segmentStatus': 'IN_PROGRESS',
      'plannedQty': 10000,
      'remainingReportQty': 10000,
      'materialKindCount': 3,
      'materialIssuedKindCount': 2,
      'materialPartialIssuedKindCount': 1,
    });
    final stage = workshopTaskFlowStage(partial, l10n: l10n);
    expect(stage.tone, ProductionFlowTone.activePartial);
    expect(productionFlowBadgeType(stage), UtenStatusBadgeType.violet);
    final full = ProductionExecutionWorkbenchSegment.fromJson({
      'segmentStatus': 'IN_PROGRESS',
      'plannedQty': 10000,
      'remainingReportQty': 10000,
      'materialKindCount': 3,
      'materialIssuedKindCount': 3,
    });
    expect(
      productionFlowBadgeType(workshopTaskFlowStage(full, l10n: l10n)),
      UtenStatusBadgeType.info,
    );
  });
  for (final value in fixture['cases'] as List) {
    final sample = value as Map<String, dynamic>;
    test('shared workshop stage: ${sample['name']}', () {
      expect(fixture['contractVersion'], 1);
      final task = ProductionExecutionWorkbenchSegment.fromJson(
        sample['task'] as Map<String, dynamic>,
      );
      expect(
        workshopTaskFlowStage(task, l10n: l10n).displayLabel,
        sample['label'],
      );
    });
  }
  test(
    'local drafts remain a UI overlay and never imply approved completion',
    () {
      final task = ProductionExecutionWorkbenchSegment.fromJson({
        'segmentStatus': 'IN_PROGRESS',
        'remainingReportQty': 10,
        'plannedQty': 10,
      });
      expect(
        workshopTaskFlowStage(
          task,
          l10n: l10n,
          draftReportedQty: 10,
        ).displayLabel,
        '报工草稿待审核',
      );
      expect(workshopTaskFlowStage(task, l10n: l10n).displayLabel, '生产中 · 可报工');
    },
  );
}
