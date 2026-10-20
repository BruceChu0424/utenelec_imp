package com.uten.imp.features.master.history;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/master/inline-edit")
@RequiredArgsConstructor
@PreAuthorize("isAuthenticated()")
public class MasterInlineEditController {
    private final MasterInlineEditService service;
    public record Patch(@NotNull Map<String,Object> expected,@NotEmpty Map<String,Object> changes) {}

    @PatchMapping("/{entityType}/{id}")
    public Object patch(@PathVariable String entityType,@PathVariable UUID id,@Valid @RequestBody Patch patch) {
        return service.patch(entityType,id,patch.expected(),patch.changes());
    }
}
