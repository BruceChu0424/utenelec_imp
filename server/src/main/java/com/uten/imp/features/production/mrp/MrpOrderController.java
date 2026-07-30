package com.uten.imp.features.production.mrp;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * 订单物料分析 API（D3 · 李主管）：收到确定（已审）订单后即 BOM 展开分析，不必先建生产计划。
 * 返回同 MRP 预览行（毛需求/库存/在途/净需求，自制件标记）；前端策略 chip 选择按毛/净查看。
 */
@RestController
@RequestMapping("/api/production/mrp")
@RequiredArgsConstructor
public class MrpOrderController {

    private final MrpService mrpService;

    /** 订单物料需求预览（仅已审核销售订货单）。 */
    @GetMapping("/order-preview")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public List<MrpRow> orderPreview(@RequestParam UUID orderId) {
        return mrpService.previewOrder(orderId);
    }
}
