package com.uten.imp.features.admin.crypto;

import com.uten.imp.security.PiiKeyRotationService;
import com.uten.imp.security.RequiresStepUp;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.RequiredArgsConstructor;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Profile;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/admin/pii-key-rotation")
@Profile("!cloud")
@ConditionalOnProperty(prefix="uten.crypto.rotation",name="enabled",havingValue="true")
@PreAuthorize("principal.superAdmin and hasAuthority('pii_key_rotation:manage')")
@RequiredArgsConstructor
public class PiiKeyRotationController {
    private final PiiKeyRotationService service;
    public record BatchRequest(@NotNull UUID runId, @NotBlank String targetVersion,
                               @Min(0) long expectedSequence, @Min(1) @Max(100) int limit) { }

    @GetMapping("/{runId}")
    public PiiKeyRotationService.Progress status(@PathVariable UUID runId) { return service.status(runId); }

    @PostMapping("/batches")
    @RequiresStepUp
    public PiiKeyRotationService.Progress batch(@Valid @RequestBody BatchRequest request) {
        return service.batch(request.runId(),request.targetVersion(),request.expectedSequence(),request.limit());
    }
}
