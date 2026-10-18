package com.uten.imp.features.webinquiry.management;

import com.uten.imp.security.RequiresStepUp;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.Map;

@RestController
@RequestMapping("/api/website-management")
@PreAuthorize("hasAuthority('website:view') and !principal.visitor")
@RequiredArgsConstructor
public class WebsiteManagementController {
    private final WebsiteManagementService service;
    @GetMapping
    public ResponseEntity<Map<String,Object>> current(){return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.current());}
    @PutMapping("/config")
    @RequiresStepUp
    @PreAuthorize("hasAuthority('website:view') and hasAuthority('authorization:manage') and principal.superAdmin and !principal.visitor")
    public Map<String,Object> update(@Valid @RequestBody WebsiteManagementService.ConfigUpdate request){return service.update(request);}
    @PostMapping("/check")
    public WebsiteManagementService.Status check(){return service.check();}
    @PostMapping("/open")
    public ResponseEntity<WebsiteManagementService.OpenResult> open(@Valid @RequestBody WebsiteManagementService.OpenRequest request){
        return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.open(request));
    }
}
