package com.uten.imp.features.master.learning;

import com.uten.imp.common.web.PageResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/**
 * 客户资料「货品对照」(ADR-134): 系统从保存的报价/订货单里学到的「客户的叫法 → 我们的货品」。
 *
 * <ul>
 *   <li>{@code GET /api/master/clients/{id}/goods-aliases?page&size&keyword}: client:view + 对客户有读范围</li>
 *   <li>{@code DELETE /api/master/clients/{id}/goods-aliases/{aliasId}}: client:edit + 对客户有写范围,
 *       且对照必须属于这个客户</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/master/clients/{id}/goods-aliases")
@RequiredArgsConstructor
public class ClientGoodsAliasController {

    private final ClientGoodsAliasService service;

    @GetMapping
    @PreAuthorize("hasAuthority('client:view')")
    public PageResponse<ClientGoodsAliasView> list(
            @PathVariable UUID id,
            @RequestParam(required = false) String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.list(id, keyword, page, size);
    }

    @DeleteMapping("/{aliasId}")
    @PreAuthorize("hasAuthority('client:edit')")
    public ResponseEntity<Void> delete(@PathVariable UUID id, @PathVariable UUID aliasId) {
        service.delete(id, aliasId);
        return ResponseEntity.noContent().build();
    }
}
