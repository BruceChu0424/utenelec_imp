package com.uten.imp.features.warehouse.materialbin.close;

import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseDtos.CloseStatusView;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseDtos.ReopenRequest;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseDtos.RetryRequest;
import com.uten.imp.security.RequiresStepUp;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/** 车间内料仓一期的结算状态、立即重试与撤销结算 (ADR-131 §5.8、§5.9)。 */
@RestController
@RequestMapping("/api/workshop-material")
public class WorkshopMaterialCloseController {

    private final WorkshopMaterialCloseService closes;

    public WorkshopMaterialCloseController(WorkshopMaterialCloseService closes) {
        this.closes = closes;
    }

    /** 页面每 2 秒轮询 (最多 60 秒); 只给业务文案。 */
    @GetMapping("/periods/{periodId}/close-status")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public CloseStatusView status(@PathVariable UUID periodId) {
        return closes.status(periodId);
    }

    /** "立即重试" / "重新结算": 202, 结算在后台执行, 页面随后轮询。 */
    @PostMapping("/periods/{periodId}/close-retry")
    @PreAuthorize("hasAuthority('workshop_material:count')")
    public ResponseEntity<CloseStatusView> retry(@PathVariable UUID periodId, @RequestBody RetryRequest request) {
        return ResponseEntity.accepted().body(closes.retry(periodId, request));
    }

    /** 撤销结算: 只能逐人授予的权限 + 再输入一次登录密码 (ADR-110)。 */
    @PostMapping("/periods/{periodId}/reopen")
    @PreAuthorize("hasAuthority('workshop_material:reopen')")
    @RequiresStepUp
    public CloseStatusView reopen(@PathVariable UUID periodId, @RequestBody ReopenRequest request) {
        return closes.reopen(periodId, request);
    }
}
