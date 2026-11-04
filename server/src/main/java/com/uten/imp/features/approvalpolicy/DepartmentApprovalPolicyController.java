package com.uten.imp.features.approvalpolicy;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;

@RestController
@RequestMapping("/api/approval-policy/departments")
@PreAuthorize("hasAuthority('approval_policy:manage')")
@RequiredArgsConstructor
public class DepartmentApprovalPolicyController {
    private final DepartmentApprovalPolicyService service;
    @GetMapping public Map<String,Object> departments(){return Map.of("departments",service.departments());}
    @GetMapping("/{departmentId}/candidates") public Map<String,Object> candidates(@PathVariable UUID departmentId,@RequestParam(required=false)String search){return Map.of("items",service.candidates(departmentId,search));}
    @PutMapping("/{departmentId}") public DepartmentApprovalPolicyService.DepartmentPolicy update(@PathVariable UUID departmentId,@RequestBody DepartmentApprovalPolicyService.Update input){return service.update(departmentId,input);}
}
