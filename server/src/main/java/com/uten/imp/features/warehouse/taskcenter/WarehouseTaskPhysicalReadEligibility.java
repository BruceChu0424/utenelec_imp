package com.uten.imp.features.warehouse.taskcenter;

import java.util.LinkedHashMap;
import java.util.List;

/** A broader browse relationship cannot manufacture a physical command relationship. */
final class WarehouseTaskPhysicalReadEligibility {
    private WarehouseTaskPhysicalReadEligibility() { }

    static WarehouseTaskCenterContracts.Row retain(WarehouseTaskCenterContracts.Row row,boolean physical,boolean outbound) {
        if (physical) return row;
        var data=new LinkedHashMap<>(row.actionData());
        for (String flag:List.of("canEdit","canApprove","canRegisterBeforeInspection","reversible")) {
            if (data.containsKey(flag)) data.put(flag,false);
        }
        if (data.containsKey("allowedWarehouseTargets")) data.put("allowedWarehouseTargets",List.of());
        data.put("historyEndpoint","/warehouse/task-center/"+(outbound?"outbound/":"inbound/")+row.rowKey()+"/detail");
        return new WarehouseTaskCenterContracts.Row(row.rowKey(),row.id(),row.sourceType(),row.recordType(),row.billNo(),
                row.sourceDocNo(),row.businessDate(),row.partyName(),row.warehouseName(),row.responsibleName(),row.makerName(),
                row.lineCount(),row.status(),row.statusLabel(),row.tone(),"HISTORY_DETAIL",row.targetId(),false,data,row.line(),row.productionOrderNo());
    }

}
