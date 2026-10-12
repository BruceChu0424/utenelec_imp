package com.uten.imp.features.admin.platformsetting;

import com.uten.imp.security.RequiresStepUp;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/admin/platform-settings")
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin and !principal.visitor")
public class PlatformSettingsController {
    private final PlatformSettingsService service;

    @GetMapping
    public ResponseEntity<PlatformBrandingDto> current() {
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.current());
    }

    @GetMapping("/status")
    public ResponseEntity<PlatformSettingsService.Status> status() {
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.status());
    }

    @PutMapping
    @RequiresStepUp
    public PlatformBrandingDto update(@Valid @RequestBody PlatformBrandingDto.Update request) {
        return service.update(request);
    }
}
