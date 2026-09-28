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
}
