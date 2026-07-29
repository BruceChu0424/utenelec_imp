package com.uten.imp.features.production.mrp;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * MRP-lite 接口：生产计划物料需求预览 + 一键生成采购申请。
 * 预览=查看（production_plan:view）；生成=维护（production_plan:edit，产出物为采购申请草稿）。
 */
@RestController
@RequestMapping("/api/production/plans")
@RequiredArgsConstructor
public class MrpController {

    private final MrpService mrpService;

    /** 物料需求预览（毛需求/库存/在途/净需求，自制件标记）。 */
    @GetMapping("/{id}/mrp")
    @PreAuthorize("hasAuthority('production_plan:view')")
    public List<MrpRow> preview(@PathVariable UUID id) {
        return mrpService.preview(id);
    }

    /** 按净需求生成采购申请（草稿）；已生成过且单据有效时 409 业务错误。
     *  D3：strategy=gross 按毛需求开单（不扣库存/在途）。 */
    @PostMapping("/{id}/mrp/generate")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public MrpGenerateResult generate(@PathVariable UUID id,
                                      @org.springframework.web.bind.annotation.RequestParam(required = false) String strategy) {
        return mrpService.generate(id, strategy);
    }

    /** 按 BOM 毛需求生成生产领料单（草稿，body 传 warehouseId）；防重复规则同采购申请。 */
    @PostMapping("/{id}/mrp/generate-draw")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public MrpGenerateResult generateDraw(@PathVariable UUID id,
                                          @org.springframework.web.bind.annotation.RequestBody GenerateDrawBody body) {
        return mrpService.generateDraw(id, body == null ? null : body.warehouseId());
    }

    /** 按计划明细（排产量−已入库量）生成成品入库单（草稿，body 传 warehouseId）。 */
    @PostMapping("/{id}/mrp/generate-finished-in")
    @PreAuthorize("hasAuthority('production_plan:edit')")
    public MrpGenerateResult generateFinishedIn(@PathVariable UUID id,
                                                @org.springframework.web.bind.annotation.RequestBody GenerateDrawBody body) {
        return mrpService.generateFinishedIn(id, body == null ? null : body.warehouseId());
    }

    /** 生成领料单请求体。 */
    public record GenerateDrawBody(UUID warehouseId) {}
}
