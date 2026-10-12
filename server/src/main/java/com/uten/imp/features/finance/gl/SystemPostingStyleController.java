package com.uten.imp.features.finance.gl;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.List;

/** Complete missing operational account assignments through the same scoped finance UI. */
@RestController
@RequestMapping("/api/finance/posting-style-roles")
@RequiredArgsConstructor
public class SystemPostingStyleController {
    private final SystemPostingStyleService service;

    @GetMapping
    @PreAuthorize("hasAuthority('payment_style:view') and hasAuthority('finance_post:execute')")
    public List<SystemPostingStyleService.Role> list() { return service.list(); }

    @PutMapping("/{roleKey}")
    @PreAuthorize("hasAuthority('payment_style:edit') and hasAuthority('finance_post:execute')")
    public SystemPostingStyleService.Role configure(@PathVariable String roleKey,
            @Valid @RequestBody SystemPostingStyleService.Configure request) {
        return service.configure(roleKey, request);
    }
}
