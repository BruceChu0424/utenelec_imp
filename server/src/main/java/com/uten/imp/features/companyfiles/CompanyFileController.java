package com.uten.imp.features.companyfiles;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.features.companyfiles.CompanyFileDtos.*;
import com.uten.imp.security.RequiresStepUp;

import jakarta.validation.Valid;

import lombok.RequiredArgsConstructor;

import org.springframework.http.HttpStatus;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/company-files")
@RequiredArgsConstructor
public class CompanyFileController {
    private final CompanyFileService service;
    private final AuditDetailViewRecorder detailViewAudit;

    @GetMapping
    @PreAuthorize("hasAuthority('company_file:view')")
    public Listing list(
            @RequestParam(required = false) UUID parentId,
            @RequestParam(required = false) String search,
            @RequestParam(defaultValue = "manual") String sort,
            @RequestParam(defaultValue = "asc") String direction,
            @RequestParam(defaultValue = "false") boolean trash,
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "100") int size) {
        var searches = ColumnKeywordSearch.requestValues(ColumnKeywordSearch.currentRequest());
        return searches.isEmpty() ? service.list(parentId, search, sort, direction, trash, page, size)
                : service.list(parentId, search, sort, direction, trash, page, size, searches);
    }

    @GetMapping("/principals")
    // V958: action authority is folder ACL or a global administration code.
    @PreAuthorize("hasAuthority('company_file:view')")
    public List<Principal> principals(
            @RequestParam(defaultValue = "USER") String type,
            @RequestParam(defaultValue = "") String search) {
        return service.principals(type, search);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAuthority('company_file:view')")
    public Entry detail(@PathVariable UUID id) {
        Entry result = service.detail(id);
        // Record only resolved metadata access; names and document contents stay out of the audit.
        detailViewAudit.record(
                "view_company_file_detail", "company_file_nodes", result.id(), null, null, "公司资料");
        return result;
    }

    @PostMapping("/folders")
    @PreAuthorize("hasAuthority('company_file:view')")
    @ResponseStatus(HttpStatus.CREATED)
    public Entry createFolder(@Valid @RequestBody Create request) {
        return service.createFolder(request);
    }

    @PostMapping("/files")
    @PreAuthorize("hasAuthority('company_file:view')")
    @ResponseStatus(HttpStatus.CREATED)
    public Entry reserveFile(@Valid @RequestBody Create request) {
        return service.reserveFile(request);
    }

    @PostMapping("/{id}/complete")
    @PreAuthorize("hasAuthority('company_file:view')")
    public Entry complete(@PathVariable UUID id, @Valid @RequestBody Complete request) {
        return service.complete(id, request);
    }

    @PatchMapping("/{id}")
    @PreAuthorize("hasAuthority('company_file:view')")
    public Entry edit(@PathVariable UUID id, @Valid @RequestBody Edit request) {
        return service.edit(id, request);
    }

    @PostMapping("/{id}/move")
    @PreAuthorize("hasAuthority('company_file:view')")
    public Entry move(@PathVariable UUID id, @Valid @RequestBody Move request) {
        return service.move(id, request);
    }

    @PostMapping("/reorder")
    @PreAuthorize("hasAuthority('company_file:view')")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void reorder(@Valid @RequestBody Reorder request) {
        service.reorder(request);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('company_file:view')")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable UUID id, @RequestParam long version) {
        service.delete(id, version);
    }

    @PostMapping("/{id}/restore")
    @PreAuthorize("hasAuthority('company_file:view')")
    public Entry restore(@PathVariable UUID id, @Valid @RequestBody Version request) {
        return service.restore(id, request);
    }

    @GetMapping("/{id}/permissions")
    @PreAuthorize("hasAuthority('company_file:view')")
    public Permissions permissions(@PathVariable UUID id) {
        return service.permissions(id);
    }

    @PutMapping("/{id}/permissions")
    @PreAuthorize("hasAuthority('company_file:view')")
    @RequiresStepUp
    public Entry setPermissions(@PathVariable UUID id, @Valid @RequestBody Permissions request) {
        return service.setPermissions(id, request);
    }

    @PutMapping("/{id}/password")
    @PreAuthorize("hasAuthority('company_file:view')")
    @RequiresStepUp
    public Entry setPassword(@PathVariable UUID id, @Valid @RequestBody Password request) {
        return service.setPassword(id, request);
    }

    @PostMapping("/{id}/unlock")
    @PreAuthorize("hasAuthority('company_file:view')")
    public Unlocked unlock(@PathVariable UUID id, @Valid @RequestBody Unlock request) {
        return service.unlock(id, request);
    }

    @PostMapping("/{id}/lock")
    @PreAuthorize("hasAuthority('company_file:view')")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void lock(@PathVariable UUID id) {
        service.lock(id);
    }
}
