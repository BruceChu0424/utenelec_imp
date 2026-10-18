package com.uten.imp.features.auth;

import com.uten.imp.security.RequiresStepUp;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

import java.util.UUID;

@RestController
@RequestMapping("/api/auth/mfa")
@RequiredArgsConstructor
public class RemoteMfaController {
    private final RemoteMfaService mfa;
    public record Code(@NotBlank @Size(max = 16) String otpCode) {
        @Override public String toString() { return "Code[REDACTED]"; }
    }
    public record Reset(@NotBlank @Size(max = 256) String reason) {}

    @GetMapping
    public RemoteMfaService.Status status() { return mfa.status(); }

    @PostMapping("/enrollment")
    @RequiresStepUp
    public RemoteMfaService.Enrollment enrollment(HttpServletResponse response) {
        response.setHeader("Cache-Control", "no-store");
        response.setHeader("Pragma", "no-cache");
        return mfa.beginEnrollment();
    }

    @PostMapping("/confirm")
    public RemoteMfaService.Status confirm(@Valid @RequestBody Code request) { return mfa.confirmEnrollment(request.otpCode()); }

    @PostMapping("/verify")
    public RemoteMfaService.Verified verify(@Valid @RequestBody Code request) { return mfa.verifySession(request.otpCode()); }

    @PostMapping("/disable")
    @RequiresStepUp
    public RemoteMfaService.Revoked disable(@Valid @RequestBody Code request) { return mfa.disable(request.otpCode()); }

    @PostMapping("/users/{userId}/reset")
    @RequiresStepUp
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public RemoteMfaService.Revoked reset(@PathVariable UUID userId, @Valid @RequestBody Reset request) {
        return mfa.reset(userId, request.reason());
    }
}
