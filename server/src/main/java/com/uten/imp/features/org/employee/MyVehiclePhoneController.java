package com.uten.imp.features.org.employee;

import com.uten.imp.features.org.employee.dto.NestedDtos;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

/**
 * 员工自助：本人车辆与备用手机号（ADR-021 §二）。
 * 直改字段（与现住址/邮箱同级，不需 HR 审核）；数据范围仅本人。
 * 备用手机号本人可见明文；权限点沿用 profile:edit:self（全员基础）。
 */
@RestController
@RequestMapping("/api/profile/me")
@RequiredArgsConstructor
public class MyVehiclePhoneController {

    private final EmployeeVehiclePhoneService vehiclePhoneService;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    @GetMapping("/vehicles")
    @PreAuthorize("hasAuthority('profile:edit:self')")
    public List<NestedDtos.VehicleDto> myVehicles() {
        tx.bind();
        return vehiclePhoneService.listVehicles(currentUser.requireEmployeeId());
    }

    @PutMapping("/vehicles")
    @PreAuthorize("hasAuthority('profile:edit:self')")
    @org.springframework.transaction.annotation.Transactional
    public List<NestedDtos.VehicleDto> replaceMyVehicles(
            @Valid @RequestBody List<NestedDtos.VehicleInput> inputs) {
        tx.bind();
        Employee me = requireMe();
        vehiclePhoneService.replaceVehicles(me, inputs);
        return vehiclePhoneService.listVehicles(me.getId());
    }

    @GetMapping("/phones")
    @PreAuthorize("hasAuthority('profile:edit:self')")
    public List<NestedDtos.PhoneDto> myPhones() {
        tx.bind();
        return vehiclePhoneService.listPhones(currentUser.requireEmployeeId()).stream()
                .map(p -> new NestedDtos.PhoneDto(p.id(), p.label(), p.phonePlain()))
                .toList();
    }

    @PutMapping("/phones")
    @PreAuthorize("hasAuthority('profile:edit:self')")
    @org.springframework.transaction.annotation.Transactional
    public List<NestedDtos.PhoneDto> replaceMyPhones(
            @Valid @RequestBody List<NestedDtos.PhoneInput> inputs) {
        tx.bind();
        Employee me = requireMe();
        vehiclePhoneService.replacePhones(me, inputs);
        return myPhones();
    }

    private Employee requireMe() {
        return vehiclePhoneService.requireEmployee(currentUser.requireEmployeeId());
    }
}
