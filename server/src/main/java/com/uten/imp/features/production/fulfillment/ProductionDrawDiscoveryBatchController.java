package com.uten.imp.features.production.fulfillment;

import com.uten.imp.features.stock.dto.StockDocIssueBatchResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/stock/docs")
@RequiredArgsConstructor
public class ProductionDrawDiscoveryBatchController {
    private final ProductionDrawDiscoveryBatchService service;

    @PostMapping("/issue-discovery-batch")
    @PreAuthorize("hasAuthority('stock_doc:view') and hasAuthority('stock_doc:approve') and hasAuthority('stock_doc:issue')")
    public StockDocIssueBatchResponse issue(@RequestBody ProductionDrawDiscoveryBatchContracts.Request request) {
        return service.issue(request);
    }
}
