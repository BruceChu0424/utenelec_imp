package com.uten.imp.features.clientupdates;

import java.nio.charset.StandardCharsets;
import java.util.UUID;
import lombok.RequiredArgsConstructor;
import org.springframework.core.io.InputStreamResource;
import org.springframework.core.io.Resource;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/** Every authenticated app can discover its compatible client release without server-operation privileges. */
@RestController
@RequestMapping("/api/client-updates")
@PreAuthorize("isAuthenticated()")
@RequiredArgsConstructor
public class ClientUpdateController {
    private final ClientReleaseService service;

    @GetMapping("/check")
    public ResponseEntity<ClientReleaseDto.Check> check(@RequestParam("platform") String platform,
            @RequestParam("architecture") String architecture, @RequestParam("currentBuildNumber") long currentBuildNumber) {
        return ResponseEntity.ok().header(HttpHeaders.CACHE_CONTROL, "private, no-store")
                .body(service.check(platform, architecture, currentBuildNumber));
    }

    @GetMapping("/{id}/download")
    public ResponseEntity<Resource> download(@PathVariable("id") UUID id) {
        ClientReleaseService.Download download = service.download(id);
        var release = download.release();
        return ResponseEntity.ok().contentType(MediaType.APPLICATION_OCTET_STREAM).contentLength(release.sizeBytes())
                .header(HttpHeaders.CONTENT_DISPOSITION, ContentDisposition.attachment()
                        .filename(release.fileName(), StandardCharsets.UTF_8).build().toString())
                .header(HttpHeaders.CACHE_CONTROL, "private, no-store")
                .header("X-Content-Type-Options", "nosniff")
                .header("X-Checksum-Sha256", release.sha256())
                .body(new InputStreamResource(download.stream()));
    }
}
