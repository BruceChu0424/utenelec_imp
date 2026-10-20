package com.uten.imp.features.master.goods;

import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.goods.dto.BomPasteResult;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
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
 * - POST /api/master/goods/bom/paste → 兼容复制新货品等既有流程的追加，整批原子；
 *   任何一处不合格返回 409 + 逐条原因(fieldErrors)，现有组件不动。
 *   追加要 goods:bom:create；整份覆盖必须使用批量维护的 OVERWRITE 预览/确认入口。
 */
@RestController
@RequestMapping("/api/master/goods/bom")
@RequiredArgsConstructor
public class GoodsBomPasteController {

    private final GoodsBomPasteService service;

    @PostMapping("/paste")
    @PreAuthorize("hasAuthority('goods:bom:create')")
    public BomPasteResult paste(@Valid @RequestBody BomPasteRequest request) {
        if (request.mode() == BomPasteRequest.Mode.REPLACE) {
            throw new ApiException(ErrorCode.CONFLICT,
                    "整份覆盖请先预览并确认，请使用组装维护的 OVERWRITE 预览与保存入口");
        }
        return service.paste(request);
    }
}
