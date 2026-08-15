package com.uten.imp.features.production.execution;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/** 生产派工单（工卡）查看接口（按 plan + planning-package scope）。 */
@RestController
@RequestMapping(
        "/api/production/plans/{planId}/planning-packages/{packageId}/work-cards")
@RequiredArgsConstructor
public class ProductionWorkCardController {

    private final ProductionWorkCardService service;

    @GetMapping
    @PreAuthorize("hasAuthority('production_plan:view')")
    public ProductionWorkCardView view(
            @PathVariable UUID planId,
            @PathVariable UUID packageId) {
        return service.view(planId, packageId);
    }
}
