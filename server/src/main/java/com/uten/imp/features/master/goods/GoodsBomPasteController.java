package com.uten.imp.features.master.goods;

import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.goods.dto.BomPasteResult;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 粘贴组件信息(ADR-111)。
 *
 * - POST /api/master/goods/bom/paste → 把剪贴板组件行替换/追加到 1~50 个货品，整批原子；
 *   任何一处不合格返回 409 + 逐条原因(fieldErrors)，现有组件不动。
 *   追加要 goods:bom:create；替换另需 goods:bom:delete(服务层校验)。
 */
@RestController
@RequestMapping("/api/master/goods/bom")
@RequiredArgsConstructor
public class GoodsBomPasteController {

    private final GoodsBomPasteService service;

    @PostMapping("/paste")
    @PreAuthorize("hasAuthority('goods:bom:create')")
    public BomPasteResult paste(@Valid @RequestBody BomPasteRequest request) {
        return service.paste(request);
    }
}
