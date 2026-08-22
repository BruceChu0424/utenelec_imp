package com.uten.imp.features.stock.allocation;

import com.uten.imp.features.stock.allocation.dto.ProductionMaterialClearanceRow;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementRequest;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialSettlementSourceRow;
import com.uten.imp.features.stock.allocation.dto.ReturnableMaterialSourceRow;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/** Production material issue/return/clearance API for warehouse and workshop. */
@RestController
@RequiredArgsConstructor
@RequestMapping("/api/stock/production-materials")
public class ProductionMaterialSettlementController {

    private final ProductionMaterialSettlementService settlementService;
    private final ProductionMaterialStockLedgerService stockLedgerService;
    private final SecurityContextCurrentUser currentUser;

    @GetMapping("/plans/{planId}/clearance")
    @PreAuthorize("hasAnyAuthority('production_plan:view','stock_doc:view')")
    public List<ProductionMaterialClearanceRow> clearance(
            @PathVariable UUID planId) {
        return settlementService.clearance(planId);
    }

    @GetMapping("/plans/{planId}/settlements")
    @PreAuthorize("hasAnyAuthority('production_plan:view','stock_doc:view')")
    public List<ProductionMaterialSettlementSourceRow> settlementSources(
            @PathVariable UUID planId) {
        return settlementService.settlementSources(planId);
    }

    @PostMapping("/plans/{planId}/settlements")
    @PreAuthorize("hasAuthority('production_material:settle')")
    public List<ProductionMaterialClearanceRow> settle(
            @PathVariable UUID planId,
            @Valid @RequestBody ProductionMaterialSettlementRequest request) {
        return settlementService.post(
                planId, request, currentUser.requireId());
    }

    @PostMapping("/plans/{planId}/settlements/reverse")
    @PreAuthorize("hasAuthority('production_material:reverse')")
    public List<ProductionMaterialClearanceRow> reverseSettlement(
            @PathVariable UUID planId,
            @Valid @RequestBody ProductionMaterialSettlementRequest request) {
        return settlementService.reverse(
                planId, request, currentUser.requireId());
    }

    @PostMapping("/plans/{planId}/close")
    @PreAuthorize("hasAuthority('production_material:close')")
    public List<ProductionMaterialClearanceRow> close(
            @PathVariable UUID planId) {
        return settlementService.close(planId);
    }

    @GetMapping("/returnable-sources")
    @PreAuthorize("hasAuthority('stock_doc:view')")
    public List<ReturnableMaterialSourceRow> returnableSources(
            @RequestParam(required = false) UUID planId,
            @RequestParam(required = false) UUID drawId) {
        return stockLedgerService.returnableSources(planId, drawId);
    }
}
