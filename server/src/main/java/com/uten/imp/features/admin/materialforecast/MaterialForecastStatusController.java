package com.uten.imp.features.admin.materialforecast;

import lombok.RequiredArgsConstructor;
import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequiredArgsConstructor
@RequestMapping("/api/admin/system-settings/material-forecast-status")
@PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin and !principal.visitor and !principal.mustChangePassword and principal.impersonatedBy == null")
public class MaterialForecastStatusController {
    private final MaterialForecastStatusService service;
    @GetMapping public ResponseEntity<MaterialForecastStatusService.Status> read(){return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(service.read());}
}
