package com.uten.imp.features.org.department;

import com.uten.imp.features.org.department.dto.*;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/org/departments")
@RequiredArgsConstructor
public class DepartmentController {

    private final DepartmentService service;

    @GetMapping("/tree")
    @PreAuthorize("hasAuthority('department:view')")
    public List<DepartmentNode> tree() {
        return service.tree();
    }

    @GetMapping("/{id}/subtree")
    @PreAuthorize("hasAuthority('department:view')")
    public List<DepartmentNode> subtree(@PathVariable UUID id) {
        return service.subtree(id);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('department:view')")
    public DepartmentDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('department:edit')")
    public DepartmentDetail create(@Valid @RequestBody DepartmentSaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('department:edit')")
    public DepartmentDetail update(@PathVariable UUID id, @Valid @RequestBody DepartmentUpdateRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('department:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
