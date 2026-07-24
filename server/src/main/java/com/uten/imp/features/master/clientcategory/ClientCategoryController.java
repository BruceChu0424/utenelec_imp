package com.uten.imp.features.master.clientcategory;

import com.uten.imp.features.master.clientcategory.dto.*;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/master/client-categories")
@RequiredArgsConstructor
public class ClientCategoryController {

    private final ClientCategoryService service;

    @GetMapping("/tree")
    @PreAuthorize("hasAuthority('client_category:view')")
    public List<ClientCategoryNode> tree() {
        return service.tree();
    }

    @GetMapping("/{id}/subtree")
    @PreAuthorize("hasAuthority('client_category:view')")
    public List<ClientCategoryNode> subtree(@PathVariable UUID id) {
        return service.subtree(id);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('client_category:view')")
    public ClientCategoryDetail detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('client_category:edit')")
    public ClientCategoryDetail create(@Valid @RequestBody ClientCategorySaveRequest req) {
        return service.create(req);
    }

    @PutMapping("/{id}")
    @PreAuthorize("hasAuthority('client_category:edit')")
    public ClientCategoryDetail update(@PathVariable UUID id, @Valid @RequestBody ClientCategoryUpdateRequest req) {
        return service.update(id, req);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('client_category:edit')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }
}
