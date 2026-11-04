package com.uten.imp.features.finance.application;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;
import static com.uten.imp.features.finance.application.FinanceApplicationContracts.*;

@RestController @RequiredArgsConstructor
@RequestMapping("/api/finance/applications/settings")
@PreAuthorize("hasAuthority('expense:settings')")
public class FinanceApplicationSettingsController {
    private final FinanceApplicationRoles roles;
    @GetMapping public Map<String,Object> read(){return roles.settings();}
    @PostMapping public Map<String,Object> save(@RequestBody SettingsInput input){return roles.saveSettings(input);}
    @PostMapping("/roles") public Map<String,Object> role(@RequestBody RoleInput input){return roles.saveRole(input);}
    @DeleteMapping("/roles/{id}") public Map<String,Object> remove(@PathVariable UUID id,@RequestParam long expectedVersion){return roles.removeRole(id,expectedVersion);}
}
