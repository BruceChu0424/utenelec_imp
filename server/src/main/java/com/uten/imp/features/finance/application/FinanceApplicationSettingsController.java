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
    @DeleteMapping("/roles/{id}") public Map<String,Object> remove(@PathVariable UUID id,@RequestParam long expectedVersion,@RequestParam UUID requestId){return roles.removeRole(id,expectedVersion,requestId);}
    @GetMapping("/operations/{requestId}") public Map<String,Object> receipt(@PathVariable UUID requestId){return roles.settingsReceipt(requestId);}
    @PostMapping("/operations/{requestId}/cancel") public Map<String,Object> cancel(@PathVariable UUID requestId,@RequestBody com.uten.imp.features.finance.FinanceOperationJournal.Cancellation request){return roles.cancelSettings(requestId,request);}
}
