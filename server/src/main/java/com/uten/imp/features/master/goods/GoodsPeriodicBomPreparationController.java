package com.uten.imp.features.master.goods;

import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationBatchRequest;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationBatchResult;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.PreparationView;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 车间整批领料上线准备 (ADR-131 §5.1 第 2 步; 规格 §2.3 基础资料)。
 *
 * - GET  /api/master/goods/periodic-bom/preparation?workshopId= → 常做的产品、预填颗粒、单个重量与进度
 * - POST /api/master/goods/periodic-bom/batch                  → 一次保存: 填了单重的写 BOM, 只选了料的写认料
 */
@RestController
@RequestMapping("/api/master/goods/periodic-bom")
public class GoodsPeriodicBomPreparationController {
    @org.springframework.beans.factory.annotation.Autowired private PeriodicPreparationSummaryService summaries;
    @org.springframework.beans.factory.annotation.Autowired private com.uten.imp.features.warehouse.materialbin.PeriodicMaterialCandidateReadService candidates;


    private final GoodsPeriodicBomPreparationService service;

    public GoodsPeriodicBomPreparationController(GoodsPeriodicBomPreparationService service) {
        this.service = service;
    }

    @GetMapping("/preparation")
    @PreAuthorize("hasAuthority('goods:view') and hasAuthority('workshop_material:setup')")
    public PreparationView preparation(@RequestParam UUID workshopId) {
        return service.list(workshopId);
    }

    @PostMapping("/batch")
    @PreAuthorize("hasAuthority('goods:bom:create') and hasAuthority('goods:bom:edit')")
    public PreparationBatchResult batch(@Valid @RequestBody PreparationBatchRequest request) {
        return service.save(request);
    }

    @GetMapping("/preparation/summaries")
    @PreAuthorize("hasAuthority('goods:view') and hasAuthority('workshop_material:setup')")
    public PeriodicPreparationSummaryService.Summary summaries(@RequestParam UUID workshopId,@RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="1000") int size,@RequestParam(required=false) String readSnapshotRevision,@RequestParam(required=false) String windowAsOf) {
        return summaries.summaries(workshopId,page,size,readSnapshotRevision,windowAsOf);
    }
    @GetMapping("/preparation/products/{productId}")
    @PreAuthorize("hasAuthority('goods:view') and hasAuthority('workshop_material:setup')")
    public PeriodicPreparationSummaryService.Detail product(@org.springframework.web.bind.annotation.PathVariable UUID productId,@RequestParam UUID workshopId,@RequestParam(defaultValue="1000") int size,@RequestParam(required=false) String readSnapshotRevision,@RequestParam(required=false) String windowAsOf) {
        return summaries.product(workshopId,productId,size,readSnapshotRevision,windowAsOf);
    }
    @GetMapping("/preparation/material-options")
    @PreAuthorize("hasAuthority('goods:view') and hasAuthority('workshop_material:setup')")
    public com.uten.imp.common.readsnapshot.VersionedSummaryPages.Page<com.uten.imp.features.warehouse.materialbin.PeriodicMaterialCandidateReadService.Candidate> candidates(@RequestParam UUID workshopId,@RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="1000") int size,@RequestParam(required=false) String readSnapshotRevision) {
        return candidates.candidates(java.util.List.of(workshopId),true,page,size,readSnapshotRevision);
    }
}
