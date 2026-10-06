package com.uten.imp.features.ai.job;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.http.*;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.nio.charset.StandardCharsets;
import java.util.UUID;

@RestController
@RequestMapping("/api/sales/{documentKind}/{docId}/input-originals")
@PreAuthorize("isAuthenticated() and !principal.visitor")
public class AiInputOriginalController {
    private final AiInputOriginalStore originals;
    public AiInputOriginalController(AiInputOriginalStore originals){this.originals=originals;}
    @GetMapping("/{jobId}/download")
    public ResponseEntity<byte[]> download(@PathVariable String documentKind,@PathVariable UUID docId,@PathVariable UUID jobId) {
        var file=originals.download(type(documentKind),docId,jobId);
        return ResponseEntity.ok().contentType(MediaType.parseMediaType(file.contentType())).contentLength(file.bytes().length)
                .header(HttpHeaders.CONTENT_DISPOSITION,ContentDisposition.attachment().filename(file.filename(),StandardCharsets.UTF_8).build().toString())
                .header(HttpHeaders.CACHE_CONTROL,"no-store").header("X-Content-Type-Options","nosniff")
                .header("Content-Security-Policy","default-src 'none'").body(file.bytes());
    }
    private static String type(String kind){return switch(kind){case "quotes"->"quote";case "orders"->"order";default->throw new ApiException(ErrorCode.NOT_FOUND);};}
}
