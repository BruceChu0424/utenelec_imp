package com.uten.imp.features.master.goods;

import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodBatchRequest;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodBatchResult;
import com.uten.imp.features.master.goods.dto.GoodsPeriodicMaterialDtos.IssueMethodPreview;
import jakarta.validation.Valid;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 货品发料方式与分摊方式切换 (ADR-131 §5.1 第 1 步; 规格 §2.3 基础资料)。
 *
 * - GET /api/master/goods/{id}/issue-method/preview?target=PERIODIC|ORDER&costBasis=
 *       → 切换预览 (受影响 BOM 行、没清账的工单、内料仓账面、没结算期间的用量、会作废的认料、不能切换的原因)
 * - PUT /api/master/goods/issue-method/batch
 *       → 确认切换 (一次原子请求, 可多种料; 分摊方式、每袋净重、回收料的改动也只走这里)
 */
@RestController
@RequestMapping("/api/master/goods")
public class GoodsIssueMethodController {

    private final GoodsIssueMethodService service;

    public GoodsIssueMethodController(GoodsIssueMethodService service) {
        this.service = service;
    }

    @GetMapping("/{id}/issue-method/preview")
    @PreAuthorize("hasAuthority('goods:view')")
    public IssueMethodPreview preview(@PathVariable UUID id, @RequestParam String target,
                                      @RequestParam(required = false) String costBasis) {
        return service.preview(id, target, costBasis);
    }

    @PutMapping("/issue-method/batch")
    @PreAuthorize("hasAuthority('goods:edit') and hasAuthority('goods:bom:edit')")
    public IssueMethodBatchResult batch(@Valid @RequestBody IssueMethodBatchRequest request) {
        return service.batch(request);
    }
}
