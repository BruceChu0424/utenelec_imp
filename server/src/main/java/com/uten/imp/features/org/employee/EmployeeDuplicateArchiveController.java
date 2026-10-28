package com.uten.imp.features.org.employee;

import com.uten.imp.features.org.employee.dto.ArchiveEmployeeDuplicateRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.*;
import java.util.Map;
import java.util.UUID;

@RestController
@RequestMapping("/api/org/employees/{id}/duplicate-archive")
@RequiredArgsConstructor
public class EmployeeDuplicateArchiveController {
    private final EmployeeDuplicateArchiveService service;
    @GetMapping("/preview")
    public EmployeeDuplicateArchiveService.Preview preview(@PathVariable UUID id,@RequestParam String retainedCode) {
        return service.preview(id,retainedCode);
    }
    // Destructive merge is an owner-operated, preimage-verified maintenance
    // action. Ordinary employee editing permissions never expose a write route.
    public Map<String,UUID> archive(@PathVariable UUID id,@Valid @RequestBody ArchiveEmployeeDuplicateRequest request) {
        return Map.of("retainedEmployeeId",service.archive(id,request));
    }
}
