package com.uten.imp.features.ai.chat;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;
import java.util.UUID;

/**
 * ADR-150 confirmation-card endpoints for client-executed actions. A proposal needs ai:use only; the
 * page handler executed after confirmation keeps its own permission and server validation.
 * Server-executed actions (permission grant) are confirmed on their own step-up endpoint.
 */
@RestController
@RequestMapping("/api/ai/chat/actions")
@PreAuthorize("isAuthenticated() and !principal.visitor")
public class AiChatActionController {
    private final AiChatActionProposalService proposals;

    public AiChatActionController(AiChatActionProposalService proposals) { this.proposals = proposals; }

    public record ReceiptRequest(@NotBlank @Pattern(regexp = "SUCCEEDED|FAILED") String outcome,
                                 @Size(max = 500) String message) {}

    @GetMapping("/{id}")
    public Map<String, Object> view(@PathVariable UUID id) { return proposals.view(id); }

    /** One-time consumption; the response carries the exact arguments the page handler must use. */
    @PostMapping("/{id}/confirm")
    public Map<String, Object> confirm(@PathVariable UUID id) { return proposals.confirmClient(id); }

    @PostMapping("/{id}/cancel")
    public Map<String, Object> cancel(@PathVariable UUID id) { return proposals.cancel(id); }

    /** Execution receipt after the page handler finished (or failed); recorded once. */
    @PostMapping("/{id}/receipt")
    public Map<String, Object> receipt(@PathVariable UUID id, @Valid @RequestBody ReceiptRequest request) {
        return proposals.receipt(id, request.outcome(), request.message());
    }
}
