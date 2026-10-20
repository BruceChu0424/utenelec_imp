package com.uten.imp.features.master.goods;

import com.uten.imp.features.master.goods.dto.BomBatchMaintenanceCommit;
import com.uten.imp.features.master.goods.dto.BomBatchMaintenancePreview;
import com.uten.imp.features.master.goods.dto.BomBatchMaintenanceRequest;
import com.uten.imp.features.master.goods.dto.BomBatchMaintenanceResult;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/master/goods/bom/batch-maintenance")
@PreAuthorize("hasAuthority('goods:bom:edit')")
@RequiredArgsConstructor
public class GoodsBomBatchMaintenanceController {
    private final GoodsBomBatchMaintenanceService service;

    @PostMapping("/preview")
    public BomBatchMaintenancePreview preview(@Valid @RequestBody BomBatchMaintenanceRequest request) {
        return service.preview(request);
    }

    @PostMapping("/commit")
    public BomBatchMaintenanceResult commit(@Valid @RequestBody BomBatchMaintenanceCommit request) {
        return service.commit(request);
    }
}
