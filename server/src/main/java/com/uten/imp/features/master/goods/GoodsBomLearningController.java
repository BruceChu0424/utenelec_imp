package com.uten.imp.features.master.goods;

import com.uten.imp.features.master.goods.dto.BomRelearnRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 「BOM 学习记录」(ADR-129)：
 * - GET  /api/master/goods/{id}/bom-learning         → 父件档案 + 设计/真实使用数量 + 选料证据 + canRelearn(goods:view)
 * - POST /api/master/goods/{id}/bom-learning/relearn → 某组件从现在起重新学习，返回同一份记录(goods:bom:edit)
 */
@RestController
@RequiredArgsConstructor
public class GoodsBomLearningController {
    private final GoodsBomLearningQueryService service;

    @GetMapping("/api/master/goods/{id}/bom-learning")
    @PreAuthorize("hasAuthority('goods:view')")
    public GoodsBomLearningQueryService.Summary summary(@PathVariable UUID id) {
        return service.summary(id);
    }

    @PostMapping("/api/master/goods/{id}/bom-learning/relearn")
    @PreAuthorize("hasAuthority('" + GoodsBomLearningQueryService.RELEARN_PERMISSION + "')")
    public GoodsBomLearningQueryService.Summary relearn(@PathVariable UUID id,
                                                        @Valid @RequestBody BomRelearnRequest request) {
        return service.relearn(id, request.componentGoodsId());
    }
}
