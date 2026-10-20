package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/master/inline-edit/goods")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('goods:edit') and hasAuthority('goods:view')")
public class GoodsInlineEditController {
    private final GoodsInlineEditService service;

    public record Patch(@NotNull Map<String, JsonNode> expected,
                        @NotEmpty Map<String, JsonNode> changes) {}

    @PatchMapping("/{id}")
    public GoodsDetail patch(@PathVariable UUID id, @Valid @RequestBody Patch patch) {
        return service.patch(id, patch.expected(), patch.changes());
    }
}
