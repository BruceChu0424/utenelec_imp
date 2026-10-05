package com.uten.imp.features.admin;

import com.uten.imp.application.port.AiChatActionProposalPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.RequiresStepUp;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/ai/chat/permission-grants")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('ai:use') and hasAuthority('authorization:manage') and principal.superAdmin")
public class AiPermissionGrantController {
    private final AiPermissionGrantService service;
    private final AiChatActionProposalPort proposals;
    public record ConfirmRequest(@NotNull UUID proposalId) {}

    /**
     * ADR-150 server-executed confirmation card. Step-up stays mandatory; the proposal is consumed once in
     * the grant transaction and a business rejection closes it so the same card cannot be retried blindly.
     */
    @PostMapping("/confirm")
    @RequiresStepUp
    public Map<String, Object> confirm(@Valid @RequestBody ConfirmRequest request) {
        try {
            return service.confirm(request.proposalId());
        } catch (ApiException rejected) {
            String code = rejected.getFieldErrors() == null ? "" : rejected.getFieldErrors().stream()
                    .filter(error -> "errorCode".equals(error.field())).map(error -> error.message()).findFirst().orElse("");
            proposals.failServerAction(request.proposalId(), code, rejected.getMessage());
            throw rejected;
        }
    }
}
