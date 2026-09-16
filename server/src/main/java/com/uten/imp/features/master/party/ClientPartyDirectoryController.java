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

import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 客户资料子表 API（V579）：多联系方式 / 多地址 / 跟进记录与信誉分。
 *
 * <ul>
 *   <li>GET/POST        /api/master/clients/{id}/contact-methods[/{cmId}]（client:view / client:edit）</li>
 *   <li>DELETE          /api/master/clients/{id}/contact-methods/{cmId}</li>
 *   <li>GET/POST/DELETE /api/master/clients/{id}/addresses[/{addressId}]</li>
 *   <li>GET/POST        /api/master/clients/{id}/activity-records</li>
 *   <li>GET             /api/master/clients/{id}/credit-score</li>
 * </ul>
 *
 * <p>联系方式增删后服务端把「每类第一条」同步回 clients 平铺列（mobile/phone/fax/
 * email/website），单据与导出继续读平铺列不受影响。
 */
@RestController
@RequestMapping("/api/master/clients")
@RequiredArgsConstructor
public class ClientPartyDirectoryController {

    private final PartyDirectoryService service;

    @GetMapping("/{id}/contact-methods")
    @PreAuthorize("hasAuthority('client:view')")
    public List<PartyContactMethod> listContacts(@PathVariable UUID id) {
        return service.listContacts(PartyDirectoryService.PartyType.CLIENT, id);
    }

    @PostMapping("/{id}/contact-methods")
    @PreAuthorize("hasAuthority('client:edit')")
    public PartyContactMethod addContact(
            @PathVariable UUID id, @Valid @RequestBody PartyContactMethodSaveRequest req) {
        return service.addContact(PartyDirectoryService.PartyType.CLIENT, id,
                req.kind(), req.value(), req.isPrimary(), req.remark());
    }

    @DeleteMapping("/{id}/contact-methods/{contactId}")
    @PreAuthorize("hasAuthority('client:edit')")
    public void deleteContact(@PathVariable UUID id, @PathVariable UUID contactId) {
        service.deleteContact(PartyDirectoryService.PartyType.CLIENT, id, contactId);
    }

    @GetMapping("/{id}/addresses")
    @PreAuthorize("hasAuthority('client:view')")
    public List<PartyAddress> listAddresses(@PathVariable UUID id) {
        return service.listAddresses(PartyDirectoryService.PartyType.CLIENT, id);
    }

    @PostMapping("/{id}/addresses")
    @PreAuthorize("hasAuthority('client:edit')")
    public PartyAddress addAddress(
            @PathVariable UUID id, @Valid @RequestBody PartyAddressSaveRequest req) {
        return service.addAddress(PartyDirectoryService.PartyType.CLIENT, id,
                req.kind(), req.address(), req.isDefault(), req.remark());
    }

    @DeleteMapping("/{id}/addresses/{addressId}")
    @PreAuthorize("hasAuthority('client:edit')")
    public void deleteAddress(@PathVariable UUID id, @PathVariable UUID addressId) {
        service.deleteAddress(PartyDirectoryService.PartyType.CLIENT, id, addressId);
    }

    @GetMapping("/{id}/activity-records")
    @PreAuthorize("hasAuthority('client:view')")
    public List<PartyActivityRecord> listActivities(@PathVariable UUID id) {
        return service.listActivities(PartyDirectoryService.PartyType.CLIENT, id);
    }

    @PostMapping("/{id}/activity-records")
    @PreAuthorize("hasAuthority('client:edit')")
    public PartyActivityRecord addActivity(
            @PathVariable UUID id, @Valid @RequestBody PartyActivityRecordSaveRequest req) {
        return service.addActivity(PartyDirectoryService.PartyType.CLIENT, id,
                req.kind(), req.content(), req.scoreDelta());
    }

    @GetMapping("/{id}/credit-score")
    @PreAuthorize("hasAuthority('client:view')")
    public Map<String, Object> creditScore(@PathVariable UUID id) {
        // 未评分的客户 credit_score 为 NULL，Map.of 不接受 null 值会 NPE。
        return Collections.singletonMap("creditScore", service.creditScore(id));
    }
}
