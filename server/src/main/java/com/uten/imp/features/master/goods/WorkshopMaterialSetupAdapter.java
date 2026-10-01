package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.WorkshopMaterialSetupPort;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodBatchRequest;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodItem;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Component
public class WorkshopMaterialSetupAdapter implements WorkshopMaterialSetupPort {
    private final GoodsIssueMethodService goods;

    public WorkshopMaterialSetupAdapter(GoodsIssueMethodService goods) { this.goods = goods; }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    @PreAuthorize("hasAuthority('goods:edit') and hasAuthority('goods:bom:edit')")
    public void setup(List<Setup> materials, String fulfilCommandKey) {
        goods.batch(new IssueMethodBatchRequest(materials.stream().map(item -> new IssueMethodItem(
                item.goodsId(), item.expectedVersion(), "PERIODIC", item.periodicCostBasis(), null, null)).toList(),
                GoodsPeriodicCommandLedger.derivedKey("WM-FIRST-ISSUE", fulfilCommandKey)));
    }
}
