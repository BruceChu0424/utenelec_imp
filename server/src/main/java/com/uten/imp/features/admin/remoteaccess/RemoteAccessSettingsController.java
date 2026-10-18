package com.uten.imp.features.admin.remoteaccess;

import com.uten.imp.security.RequiresStepUp;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/admin/remote-access")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
public class RemoteAccessSettingsController {
    private final RemoteAccessSettingsService settings;

    @GetMapping("/status")
    public RemoteAccessSettingsService.Status status() { return settings.status(); }

    @PatchMapping("/policy")
    @RequiresStepUp
    public RemoteAccessSettingsService.Policy update(@Valid @RequestBody RemoteAccessSettingsService.Change change) {
        return settings.update(change);
    }
}
