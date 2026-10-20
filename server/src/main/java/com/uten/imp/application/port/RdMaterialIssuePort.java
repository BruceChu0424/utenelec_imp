package com.uten.imp.application.port;

import java.util.Collection;
import java.util.Map;
import java.util.UUID;

/** Planning reports verified master/BOM problems without weakening production validation. */
public interface RdMaterialIssuePort {
    String MASTER_SOURCE = "MATERIAL_ANALYSIS_MASTER_ISSUE";
    String BOM_SOURCE = "MATERIAL_ANALYSIS_BOM_ISSUE";
    record Target(UUID goodsId, boolean masterData) {
        public String sourceType() { return masterData ? MASTER_SOURCE : BOM_SOURCE; }
        public String key() { return sourceType() + ":" + goodsId; }
    }
    Map<String, String> openTaskNos(Collection<Target> targets);
    String forward(Target target, UUID analysisId, String description);
}
