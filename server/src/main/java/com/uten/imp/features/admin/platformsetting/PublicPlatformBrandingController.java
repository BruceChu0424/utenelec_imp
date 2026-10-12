package com.uten.imp.features.admin.platformsetting;

import lombok.RequiredArgsConstructor;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/platform/branding")
@RequiredArgsConstructor
public class PublicPlatformBrandingController {
    private final PlatformSettingsService service;

    @GetMapping
    public ResponseEntity<PlatformBrandingDto> current() {
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.current());
    }

    @GetMapping("/logo")
    public ResponseEntity<byte[]> logo(@RequestParam(name = "v", required = false) Integer version) {
        return service.logo(version).map(bytes -> ResponseEntity.ok()
                        .contentType(MediaType.IMAGE_PNG).contentLength(bytes.length)
                        .header("X-Content-Type-Options", "nosniff")
                        .header(HttpHeaders.CONTENT_DISPOSITION, "inline; filename=logo.png")
                        .cacheControl(CacheControl.noStore()).body(bytes))
                .orElseGet(() -> ResponseEntity.notFound().cacheControl(CacheControl.noStore()).build());
    }
}
