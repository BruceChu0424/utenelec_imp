package com.uten.imp.features.production.analysis;

import com.uten.imp.features.production.execution.ProductionOverproductionRateService;
import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.math.BigDecimal;
import java.util.List;
import java.util.Set;
import java.util.UUID;

@RestController
@RequestMapping("/api/production/material-analyses/{analysisId}/overproduction-rates")
@RequiredArgsConstructor
public class MaterialAnalysisOverproductionRateController {
    private final MaterialAnalysisOverproductionRateService service;

    public record RateChange(@NotEmpty @Size(max=RequestLimits.DOCUMENT_LINES) Set<@NotNull UUID> sourceIds,
            @NotEmpty @Size(max=1000) List<@NotNull @Valid Version> expected,
            @NotNull @DecimalMin("0") @Digits(integer=3,fraction=6) BigDecimal rate,
            @NotBlank @Size(min=8,max=128) String idempotencyKey) {}
    public record Version(UUID segmentId,UUID planItemId,@NotNull @PositiveOrZero Long rateVersion) {
        @AssertTrue(message="比例修改必须指定唯一的工单或待审核计划明细")
        public boolean isValidTarget() { return (segmentId==null)!=(planItemId==null); }
    }

    @GetMapping
    @PreAuthorize("hasAuthority('production_material_analysis:view')")
    public List<ProductionOverproductionRateService.PlanningRate> context(@PathVariable UUID analysisId,
            @RequestParam Set<UUID> sourceIds) {
        return service.context(analysisId,sourceIds);
    }

    @PutMapping
    @PreAuthorize("hasAuthority('production_material_analysis:view') and hasAuthority('production_material_analysis:generate')")
    public List<ProductionOverproductionRateService.PlanningRate> change(@PathVariable UUID analysisId,
            @Valid @RequestBody RateChange request) {
        return service.change(analysisId,request.sourceIds(),request.expected().stream().map(version ->
                new ProductionOverproductionRateService.PlanningRateVersion(version.segmentId(),version.planItemId(),version.rateVersion())).toList(),
                request.rate(),request.idempotencyKey());
    }
}
