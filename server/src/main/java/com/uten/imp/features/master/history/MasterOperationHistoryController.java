package com.uten.imp.features.master.history;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/master/operation-history")
@RequiredArgsConstructor
@PreAuthorize("isAuthenticated()")
public class MasterOperationHistoryController {
    private final MasterOperationHistoryService service;
    public record ReplayRequest(@NotNull @Min(0) Long expectedVersion) {}

    @GetMapping
    public MasterOperationHistoryService.History list(@RequestParam String entityType) {
        return service.list(entityType);
    }

    @PostMapping("/{id}/undo")
    public MasterOperationHistoryService.History undo(@RequestParam String entityType, @PathVariable UUID id,
                                                      @Valid @RequestBody ReplayRequest request) {
        return service.undo(entityType,id,request.expectedVersion());
    }

    @PostMapping("/{id}/redo")
    public MasterOperationHistoryService.History redo(@RequestParam String entityType, @PathVariable UUID id,
                                                      @Valid @RequestBody ReplayRequest request) {
        return service.redo(entityType,id,request.expectedVersion());
    }
}
