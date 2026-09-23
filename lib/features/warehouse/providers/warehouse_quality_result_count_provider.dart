import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/warehouse_iqc_stock_in.dart';
import '../models/warehouse_quality_result.dart';
import '../../../shared/badges/badge_registry.dart';

/// 品质部检查结果合并页「来源大类」两枚计数的来源(页内分段用)。
///
/// actionable = 轮到仓库动手(待入库 + 部分合格 + 需退回);
/// inProgress = 等待检查结果(货已收、结论在品质部手上, 仓库不用动手)。
/// 随工作台徽章汇总一次带回(ADR-108, 原端点 /warehouse/quality-results/type-counts
/// 同一次聚合), hub 卡红黄两枚(warehouseQualityResult 入口)由服务端目录按全部来源之和
/// 算好, 与这里各来源之和天然一致。
final warehouseQualityResultTypeCountsProvider =
    Provider<WarehouseQualityTypeCounts>((ref) {
      final facts = ref.watch(badgeSummaryProvider.select((s) => s.facts));
      return WarehouseQualityTypeCounts(
        actionable: {
          for (final type in WarehouseIqcStockInReceiptType.values)
            type: facts[BadgeFact.qualityResultActionable(type.apiValue)] ?? 0,
        },
        inProgress: {
          for (final type in WarehouseIqcStockInReceiptType.values)
            type: facts[BadgeFact.qualityResultInProgress(type.apiValue)] ?? 0,
        },
      );
    });
