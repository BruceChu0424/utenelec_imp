package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.application.port.DepartmentPickerNode;
import com.uten.imp.features.org.employee.dto.BusinessEmployeeReference;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/** Minimal references authorized by the owning operation, independent of HR roster authority. */
@RestController
@RequestMapping("/api/org/employee-references")
@RequiredArgsConstructor
@PreAuthorize("isAuthenticated() and !principal.visitor")
public class BusinessEmployeeReferenceController {
    private final BusinessEmployeeReferenceService service;
    @GetMapping
    public PageResponse<BusinessEmployeeReference> candidates(@RequestParam String purpose,
            @RequestParam(defaultValue="1") int page,@RequestParam(defaultValue="20") int size,
            @RequestParam(required=false) String search,@RequestParam(required=false) Set<String> statuses,
            @RequestParam(required=false) UUID departmentId,@RequestParam(defaultValue="false") boolean includeSubtree,
            @RequestParam(required=false) String accountStatus,@RequestParam(required=false) String employmentStatus) {
        return service.candidates(purpose,page,size,search,statuses,departmentId,includeSubtree,accountStatus,employmentStatus);
    }
    @GetMapping("/by-ids")
    public List<BusinessEmployeeReference> byIds(@RequestParam String purpose,@RequestParam List<UUID> ids) {return service.byIds(purpose,ids);}
    @GetMapping("/departments")
    public List<DepartmentPickerNode> departments(@RequestParam String purpose) {return service.departments(purpose);}
}
