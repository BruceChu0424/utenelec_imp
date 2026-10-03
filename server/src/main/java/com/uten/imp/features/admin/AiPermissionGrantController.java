package com.uten.imp.features.admin;

import com.uten.imp.security.RequiresStepUp;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
@RequestMapping("/api/ai/chat/permission-grants")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('ai:use') and hasAuthority('authorization:manage') and principal.superAdmin")
public class AiPermissionGrantController {
    private final AiPermissionGrantService service;
    public record ConfirmRequest(@NotBlank @Size(max = 4096) String proposalId) {}

    @PostMapping("/confirm")
    @RequiresStepUp
    public Map<String, Object> confirm(@Valid @RequestBody ConfirmRequest request) {
        return service.confirm(request.proposalId());
    }
}
