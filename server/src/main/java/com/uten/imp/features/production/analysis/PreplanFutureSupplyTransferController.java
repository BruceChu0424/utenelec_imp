package com.uten.imp.features.production.analysis;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/production/material-analyses")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('production_material_analysis:view')")
public class PreplanFutureSupplyTransferController {
    private final PreplanFutureSupplyTransferService service;
    @GetMapping("/{id}/materials/{materialId}/future-transfer-sources")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:cross_reallocate')")
    public List<PreplanFutureSupplyTransfer.Source> sources(@PathVariable UUID id,@PathVariable UUID materialId) {return service.sources(id,materialId);}
    @PostMapping("/{id}/future-transfers")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:cross_reallocate')")
    public MaterialAnalysisContracts.AnalysisView create(@PathVariable UUID id,@Valid @RequestBody PreplanFutureSupplyTransfer.Create request) {return service.create(id,request);}
    @GetMapping("/{id}/future-transfers")
    public List<PreplanFutureSupplyTransfer.Transfer> list(@PathVariable UUID id,@RequestParam(required=false) UUID materialId) {return service.list(id,materialId);}
    @PostMapping("/{id}/future-transfers/{transferId}/cancel")
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:cross_reallocate')")
    public MaterialAnalysisContracts.AnalysisView cancel(@PathVariable UUID id,@PathVariable UUID transferId,@Valid @RequestBody PreplanFutureSupplyTransfer.Cancel request) {return service.cancel(id,transferId,request);}
    @GetMapping("/{id}/future-transfers/{transferId}/replenishment-preview")
    public MaterialAnalysisContracts.CrossReallocationReplenishmentView replenishment(@PathVariable UUID id,@PathVariable UUID transferId) {return service.replenishment(id,transferId);}
    @GetMapping("/{id}/future-transfer-replenishment-preview")
    public MaterialAnalysisContracts.CrossReallocationReplenishmentView replenishmentByKey(@PathVariable UUID id,@RequestParam String idempotencyKey) {return service.replenishmentByKey(id,idempotencyKey);}
}
