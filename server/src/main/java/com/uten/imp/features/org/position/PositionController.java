package com.uten.imp.features.org.position;

import com.uten.imp.features.org.position.dto.PositionCreateRequest;
import com.uten.imp.features.org.position.dto.PositionItem;
import com.uten.imp.features.org.position.dto.PositionUpdateRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

/** 部门岗位接口（按部门 scope）：岗位列表/创建/更新/删除。 */
@RestController
@RequiredArgsConstructor
public class PositionController {

    private final PositionService service;

    @GetMapping("/api/org/departments/{deptId}/positions")
    @PreAuthorize("hasAuthority('department:view')")
    public List<PositionItem> list(@PathVariable UUID deptId) {
        return service.list(deptId);
    }

    @PostMapping("/api/org/departments/{deptId}/positions")
    @PreAuthorize("hasAuthority('department:edit')")
    public PositionItem create(@PathVariable UUID deptId, @Valid @RequestBody PositionCreateRequest req) {
        return service.create(deptId, req);
    }

    @PutMapping("/api/org/positions/{id}")
    @PreAuthorize("hasAuthority('department:edit')")
    public PositionItem update(@PathVariable UUID id, @Valid @RequestBody PositionUpdateRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/api/org/positions/{id}")
    @PreAuthorize("hasAuthority('department:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
