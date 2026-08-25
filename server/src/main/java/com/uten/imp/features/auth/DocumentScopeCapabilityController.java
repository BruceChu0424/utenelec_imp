package com.uten.imp.features.auth;

import com.uten.imp.features.auth.dto.DocumentScopeCapabilityDto;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/** Current-subject-only object capability endpoint; no target user id is accepted. */
@RestController
@RequestMapping("/api/auth/me/document-scopes")
@RequiredArgsConstructor
public class DocumentScopeCapabilityController {

    private final DocumentScopeCapabilityService service;

    @GetMapping("/{scope}")
    @PreAuthorize("isAuthenticated()")
    public DocumentScopeCapabilityDto current(@PathVariable String scope) {
        return service.current(scope);
    }
}
