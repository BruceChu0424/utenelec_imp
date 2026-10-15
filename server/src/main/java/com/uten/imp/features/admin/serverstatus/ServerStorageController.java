package com.uten.imp.features.admin.serverstatus;

import com.uten.imp.features.admin.serveroperations.ServerOperationsPermissions;
import com.uten.imp.security.RequiresStepUp;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/admin/server-storage")
@RequiredArgsConstructor
@PreAuthorize(ServerOperationsPermissions.READ_EXPRESSION)
public class ServerStorageController {
    private final ServerStorageService service;

    @GetMapping public ResponseEntity<ServerStorageView.Summary> summary() {
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.summary());
    }
    @GetMapping("/resources") public ResponseEntity<ServerStorageView.Resources> resources(
            @RequestParam ServerStorageView.Kind kind, @RequestParam(required = false) String cursor,
            @RequestParam(defaultValue = "50") int limit) {
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.resources(kind, cursor, limit));
    }
    @PostMapping("/cleanup/preview")
    @PreAuthorize(ServerOperationsPermissions.CLEANUP_EXPRESSION)
    @RequiresStepUp
    public ServerStorageView.Preview preview(@Valid @RequestBody ServerStorageView.PreviewRequest request) {
        return service.preview(request);
    }
    @PostMapping("/cleanup")
    @PreAuthorize(ServerOperationsPermissions.CLEANUP_EXPRESSION)
    @RequiresStepUp
    public ServerStorageView.Result delete(@Valid @RequestBody ServerStorageView.DeleteRequest request) {
        return service.delete(request);
    }
    @GetMapping("/cleanup/{requestId}")
    @PreAuthorize(ServerOperationsPermissions.CLEANUP_EXPRESSION)
    public ResponseEntity<ServerStorageView.Result> result(@PathVariable java.util.UUID requestId) {
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.result(requestId));
    }
}
