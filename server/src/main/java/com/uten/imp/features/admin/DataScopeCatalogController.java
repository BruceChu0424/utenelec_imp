package com.uten.imp.features.admin;

import com.uten.imp.features.admin.dto.DataScopeDefinitionDto;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/** Runtime-effective catalog for the global "可查看数据" workspace. */
@RestController
@RequestMapping("/api/admin/data-scope-catalog")
@RequiredArgsConstructor
public class DataScopeCatalogController {

    private final DataScopeCatalogService service;

    @GetMapping
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public List<DataScopeDefinitionDto> list() {
        return service.list();
    }
}
