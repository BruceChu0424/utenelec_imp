package com.uten.imp.features.master;

import com.uten.imp.common.mastercode.MasterIdentifierAvailabilityService;
import com.uten.imp.common.mastercode.MasterIdentifierAvailabilityService.Availability;
import com.uten.imp.common.mastercode.MasterIdentifierAvailabilityService.Domain;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/** Explicit permission mappings; checks never disclose the identity occupying a code. */
@RestController
@RequestMapping("/api/master")
@RequiredArgsConstructor
public class MasterIdentifierAvailabilityController {
    private final MasterIdentifierAvailabilityService service;

    @GetMapping("/goods/code-availability")
    @PreAuthorize("hasAnyAuthority('goods:create','goods:edit')")
    public Availability goods(@RequestParam String code, @RequestParam(required=false) UUID entityId,
                              @RequestParam(required=false) UUID categoryId) {
        return service.check(Domain.GOODS, code, entityId, categoryId);
    }

    @GetMapping("/clients/code-availability")
    @PreAuthorize("hasAnyAuthority('client:create','client:edit')")
    public Availability clients(@RequestParam String code, @RequestParam(required=false) UUID entityId,
                                @RequestParam(required=false) UUID categoryId) {
        return service.check(Domain.CLIENT, code, entityId, categoryId);
    }

    @GetMapping("/suppliers/code-availability")
    @PreAuthorize("hasAnyAuthority('supplier:create','supplier:edit')")
    public Availability suppliers(@RequestParam String code, @RequestParam(required=false) UUID entityId,
                                  @RequestParam(required=false) UUID categoryId) {
        return service.check(Domain.SUPPLIER, code, entityId, categoryId);
    }

    @GetMapping("/moulds/code-availability")
    @PreAuthorize("hasAnyAuthority('mould:create','mould:edit')")
    public Availability moulds(@RequestParam String code, @RequestParam(required=false) UUID entityId,
                               @RequestParam(required=false) UUID categoryId) {
        return service.check(Domain.MOULD, code, entityId, categoryId);
    }

    @GetMapping("/colors/code-availability")
    @PreAuthorize("hasAnyAuthority('color:create','color:edit')")
    public Availability colors(@RequestParam String code, @RequestParam(required=false) UUID entityId) {
        return service.check(Domain.COLOR, code, entityId);
    }

    @GetMapping("/units/code-availability")
    @PreAuthorize("hasAnyAuthority('unit:create','unit:edit')")
    public Availability units(@RequestParam String code, @RequestParam(required=false) UUID entityId) {
        return service.check(Domain.UNIT, code, entityId);
    }

    @GetMapping("/accounts/code-availability")
    @PreAuthorize("hasAnyAuthority('account:create','account:edit')")
    public Availability accounts(@RequestParam String code, @RequestParam(required=false) UUID entityId) {
        return service.check(Domain.ACCOUNT, code, entityId);
    }

    @GetMapping("/currencies/code-availability")
    @PreAuthorize("hasAnyAuthority('currency:create','currency:edit')")
    public Availability currencies(@RequestParam String code, @RequestParam(required=false) UUID entityId) {
        return service.check(Domain.CURRENCY, code, entityId);
    }

    @GetMapping("/warehouses/code-availability")
    @PreAuthorize("hasAnyAuthority('warehouse:create','warehouse:edit')")
    public Availability warehouses(@RequestParam String code, @RequestParam(required=false) UUID entityId) {
        return service.check(Domain.WAREHOUSE, code, entityId);
    }
}
