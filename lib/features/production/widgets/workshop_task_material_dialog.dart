import 'package:flutter/material.dart';

import '../../../components/feedback/uten_dialog.dart';
import '../../../shared/widgets/task_material_selection_dialog.dart';
import '../models/production_draw_request.dart';
import '../models/production_execution_workbench.dart';
import '../repositories/production_draw_request_repository.dart';
import '../repositories/production_execution_workbench_repository.dart';
import 'workshop_task_material_table.dart';

/// Read-only facts and exact source selection. Warehouse submission remains
/// exclusively in the existing draw-request review page.
Future<Set<String>?> showWorkshopTaskMaterialDialog(
  BuildContext context, {
  required ProductionExecutionWorkbenchSegment task,
  required bool canRequestDraw,
  bool Function()? isCurrent,
  Listenable? ownerChanges,
}) => UtenDialog.showAndWaitForExit<Set<String>>(
  context,
  builder: (_) => WorkshopTaskMaterialDialog(
    task: task,
    canRequestDraw: canRequestDraw,
    isCurrent: isCurrent,
    ownerChanges: ownerChanges,
  ),
);

/// 车间任务的物料弹窗：公共任务物料弹窗壳([TaskMaterialSelectionDialog]，与委外任务中心
/// 同一个)接上车间的两次读取——逐种物料事实 + 领料预览(每种需求交给领料页的来源明细)。
class WorkshopTaskMaterialDialog extends StatelessWidget {
  const WorkshopTaskMaterialDialog({
    super.key,
    required this.task,
    required this.canRequestDraw,
    this.isCurrent,
    this.ownerChanges,
  });

  final ProductionExecutionWorkbenchSegment task;
  final bool canRequestDraw;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;

  @override
  Widget build(BuildContext context) {
    final identity = [
      task.productName,
      task.segmentCode,
    ].whereType<String>().where((part) => part.isNotEmpty).join(' · ');
    return TaskMaterialSelectionDialog<ProductionWorkshopTaskMaterial>(
      dialogKey: ValueKey('workshop-material-dialog-${task.segmentId}'),
      title: identity.isEmpty ? '任务物料' : '任务物料 · $identity',
      compactTitle: '任务物料 · ${task.segmentCode}',
      keyPrefix: 'workshop-material',
      cardKeyPrefix: 'workshop-task-material',
      selectKeyPrefix: 'workshop-material-select',
      canRequestDraw: canRequestDraw,
      isCurrent: isCurrent,
      ownerChanges: ownerChanges,
      loadMaterials: (ref) => ref
          .read(productionExecutionWorkbenchRepositoryProvider)
          .workshopTaskMaterials(task.segmentId),
      entryOf: (material) => workshopTaskMaterialEntry(
        material,
        unitFallback: task.productUnitName,
      ),
      isShort: (material) => material.shortageQty > 0,
      loadDrawTargets: (ref) async {
        final preview = await ref
            .read(productionDrawRequestRepositoryProvider)
            .preview([
              ProductionDrawRequestItem(
                segmentId: task.segmentId,
                expectedVersion: task.lockVersion,
              ),
            ]);
        final targets = <String, Set<String>>{};
        for (final line in preview.lines) {
          final demandId = line.demandId;
          if (line.segmentId == task.segmentId &&
              line.qty > 0 &&
              demandId != null) {
            (targets[demandId] ??= {}).add(line.drawItemId);
          }
        }
        return targets;
      },
    );
  }
}
