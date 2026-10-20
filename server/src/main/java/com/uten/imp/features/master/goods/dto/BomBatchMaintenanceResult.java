package com.uten.imp.features.master.goods.dto;

import java.util.List;

public record BomBatchMaintenanceResult(
        BomBatchMaintenanceRequest.Action action, int selectedTargetCount, int changedTargetCount,
        int added, int updated, int removed, int skipped,
        List<BomBatchMaintenancePreview.Target> targets, int affectedProductCount, List<String> warnings) { }
