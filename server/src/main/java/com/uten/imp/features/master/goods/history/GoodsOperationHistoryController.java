package com.uten.imp.features.master.goods.history;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/master/goods/history")
@RequiredArgsConstructor
public class GoodsOperationHistoryController {
    private final GoodsOperationHistoryService service;

    public record ReplayRequest(@NotNull @Min(0) Long expectedVersion) {}

    @GetMapping
    @PreAuthorize("hasAuthority('goods:view')")
    public GoodsOperationHistoryService.History list() { return service.list(); }

    @PostMapping("/{id}/undo")
    @PreAuthorize("hasAuthority('goods:view')")
    public GoodsOperationHistoryService.History undo(@PathVariable UUID id, @Valid @RequestBody ReplayRequest body) {
        return service.undo(id, body.expectedVersion());
    }

    @PostMapping("/{id}/redo")
    @PreAuthorize("hasAuthority('goods:view')")
    public GoodsOperationHistoryService.History redo(@PathVariable UUID id, @Valid @RequestBody ReplayRequest body) {
        return service.redo(id, body.expectedVersion());
    }
}
