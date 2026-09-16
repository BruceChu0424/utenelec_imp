package com.uten.imp.features.master.party;

import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/**
 * 供应商资料子表 API（V579）：多联系方式 / 多地址 / 跟进记录。
 * 与 {@link ClientPartyDirectoryController} 同构，权限走 supplier:view / supplier:edit。
 */
@RestController
@RequestMapping("/api/master/suppliers")
@RequiredArgsConstructor
public class SupplierPartyDirectoryController {

    private final PartyDirectoryService service;

    @GetMapping("/{id}/contact-methods")
    @PreAuthorize("hasAuthority('supplier:view')")
    public List<PartyContactMethod> listContacts(@PathVariable UUID id) {
        return service.listContacts(PartyDirectoryService.PartyType.SUPPLIER, id);
    }

    @PostMapping("/{id}/contact-methods")
    @PreAuthorize("hasAuthority('supplier:edit')")
    public PartyContactMethod addContact(
            @PathVariable UUID id, @Valid @RequestBody PartyContactMethodSaveRequest req) {
        return service.addContact(PartyDirectoryService.PartyType.SUPPLIER, id,
                req.kind(), req.value(), req.isPrimary(), req.remark());
    }

    @DeleteMapping("/{id}/contact-methods/{contactId}")
    @PreAuthorize("hasAuthority('supplier:edit')")
    public void deleteContact(@PathVariable UUID id, @PathVariable UUID contactId) {
        service.deleteContact(PartyDirectoryService.PartyType.SUPPLIER, id, contactId);
    }

    @GetMapping("/{id}/addresses")
    @PreAuthorize("hasAuthority('supplier:view')")
    public List<PartyAddress> listAddresses(@PathVariable UUID id) {
        return service.listAddresses(PartyDirectoryService.PartyType.SUPPLIER, id);
    }

    @PostMapping("/{id}/addresses")
    @PreAuthorize("hasAuthority('supplier:edit')")
    public PartyAddress addAddress(
            @PathVariable UUID id, @Valid @RequestBody PartyAddressSaveRequest req) {
        return service.addAddress(PartyDirectoryService.PartyType.SUPPLIER, id,
                req.kind(), req.address(), req.isDefault(), req.remark());
    }

    @DeleteMapping("/{id}/addresses/{addressId}")
    @PreAuthorize("hasAuthority('supplier:edit')")
    public void deleteAddress(@PathVariable UUID id, @PathVariable UUID addressId) {
        service.deleteAddress(PartyDirectoryService.PartyType.SUPPLIER, id, addressId);
    }

    @GetMapping("/{id}/activity-records")
    @PreAuthorize("hasAuthority('supplier:view')")
    public List<PartyActivityRecord> listActivities(@PathVariable UUID id) {
        return service.listActivities(PartyDirectoryService.PartyType.SUPPLIER, id);
    }

    @PostMapping("/{id}/activity-records")
    @PreAuthorize("hasAuthority('supplier:edit')")
    public PartyActivityRecord addActivity(
            @PathVariable UUID id, @Valid @RequestBody PartyActivityRecordSaveRequest req) {
        return service.addActivity(PartyDirectoryService.PartyType.SUPPLIER, id,
                req.kind(), req.content(), req.scoreDelta());
    }
}
