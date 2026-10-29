package com.uten.imp.features.clientupdates;

import java.nio.charset.StandardCharsets;
import java.util.List;
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

    @GetMapping("/downloads")
    @PreAuthorize(ClientReleaseService.DOWNLOADS_EXPRESSION)
    public ResponseEntity<List<ClientReleaseDto.Release>> downloads(
            @RequestParam(value = "runtimeFamily", defaultValue = "flutter") String runtimeFamily,
            @RequestParam(value = "allRuntimeFamilies", defaultValue = "false") boolean allRuntimeFamilies,
            @RequestParam(value = "allPlatforms", defaultValue = "false") boolean allPlatforms) {
        return ResponseEntity.ok().header(HttpHeaders.CACHE_CONTROL, "private, no-store").body(allPlatforms
                ? service.downloads(runtimeFamily, allRuntimeFamilies, true) : service.downloads(runtimeFamily, allRuntimeFamilies));
    }

    public ResponseEntity<List<ClientReleaseDto.Release>> downloads(String runtimeFamily, boolean allRuntimeFamilies) {
        return downloads(runtimeFamily, allRuntimeFamilies, false);
    }

    public ResponseEntity<List<ClientReleaseDto.Release>> downloads() { return downloads("flutter", false); }

    @GetMapping("/check")
    public ResponseEntity<ClientReleaseDto.Check> check(@RequestParam("platform") String platform,
            @RequestParam("architecture") String architecture, @RequestParam("currentBuildNumber") long currentBuildNumber,
            @RequestParam(value = "runtimeFamily", defaultValue = "flutter") String runtimeFamily) {
        return ResponseEntity.ok().header(HttpHeaders.CACHE_CONTROL, "private, no-store")
                .body(service.check(platform, architecture, currentBuildNumber, runtimeFamily));
    }

    public ResponseEntity<ClientReleaseDto.Check> check(String platform, String architecture, long currentBuildNumber) {
        return check(platform, architecture, currentBuildNumber, "flutter");
    }

    @GetMapping("/{id}/download")
    public ResponseEntity<Resource> download(@PathVariable("id") UUID id,
            @RequestParam(value = "runtimeFamily", defaultValue = "flutter") String runtimeFamily) {
        ClientReleaseService.Download download = service.download(id, runtimeFamily);
        var release = download.release();
        return ResponseEntity.ok().contentType(MediaType.APPLICATION_OCTET_STREAM).contentLength(release.sizeBytes())
                .header(HttpHeaders.CONTENT_DISPOSITION, ContentDisposition.attachment()
                        .filename(release.fileName(), StandardCharsets.UTF_8).build().toString())
                .header(HttpHeaders.CACHE_CONTROL, "private, no-store")
                .header("X-Content-Type-Options", "nosniff")
                .header("X-Checksum-Sha256", release.sha256())
                .body(new InputStreamResource(download.stream()));
    }

    public ResponseEntity<Resource> download(UUID id) { return download(id, "flutter"); }
}
