package com.uten.imp.features.production.directtransfer;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import java.util.UUID;

/**
 * 报工页「转下一道工序」的候选查询(V584/V585)。
 *
 * <p>只读端点，用车间任务查看权即可；真正写事实的是报工审核那条链，
 * 由 {@code production_direct_transfer:approve} 单独把关。
 */
@RestController
@RequiredArgsConstructor
@RequestMapping("/api/production/direct-transfers")
public class ProductionWorkshopDirectTransferController {

    private final ProductionWorkshopDirectTransferService service;

    @GetMapping("/candidates")
    @PreAuthorize("hasAuthority('production_execution:view')"
            + " and hasAuthority('production_daily_report:view')")
    public ProductionWorkshopDirectTransferService.CandidateListing candidates(
            @RequestParam UUID executionSegmentId,
            @RequestParam UUID goodsId,
            @RequestParam(required = false) UUID colorId) {
        return service.candidates(executionSegmentId, goodsId, colorId);
    }
}
