package com.uten.imp.features.visitor.sms.settings;

import com.uten.imp.security.RequiresStepUp;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/admin/sms-settings")
@RequiredArgsConstructor
@PreAuthorize("!principal.visitor and !principal.mustChangePassword and principal.impersonatedBy == null and principal.superAdmin and hasAuthority('authorization:manage')")
public class SmsSettingsController {
    private final SmsSettingsService service;
    @GetMapping public ResponseEntity<SmsSettingsDto.View> current() {
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.current());
    }
    @PutMapping @RequiresStepUp public ResponseEntity<SmsSettingsDto.View> save(@Valid @RequestBody SmsSettingsDto.Save request) {
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.save(request));
    }
}
