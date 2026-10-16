package com.uten.imp.features.admin.serverstatus;

import lombok.RequiredArgsConstructor;
import com.uten.imp.features.admin.serveroperations.ServerOperationsPermissions;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/admin/server-status")
@RequiredArgsConstructor
@PreAuthorize(ServerOperationsPermissions.READ_EXPRESSION)
public class ServerStatusController {
    private final ServerStatusService service;
    @GetMapping public ServerStatusView current() { return service.current(); }
}
