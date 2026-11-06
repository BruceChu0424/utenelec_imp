package com.uten.imp.features.finance.application;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.time.LocalDate;
import java.util.*;
@RestController @RequiredArgsConstructor @RequestMapping("/api/finance/applications/{id}")
@PreAuthorize("hasAuthority('finance_application:view') and hasAuthority('finance_application:review')")
public class FinancePayrollApplicationReferenceController {
    private final FinancePayrollApplicationReferences references;
    @GetMapping("/payroll-references") public Map<String,Object> read(@PathVariable UUID id,@RequestParam String sourceFingerprint,@RequestParam UUID expectedClaimId){return references.references(id,sourceFingerprint,expectedClaimId);}
    @GetMapping("/payroll-gl-sources") public Map<String,Object> candidates(@PathVariable UUID id,@RequestParam String sourceFingerprint,@RequestParam UUID expectedClaimId,@RequestParam UUID styleId,@RequestParam(required=false)UUID auxiliaryId,@RequestParam(required=false)UUID employeeId,@RequestParam String kind,@RequestParam LocalDate accountingAsOf,@RequestParam(required=false)String search,@RequestParam(required=false)UUID entryId,@RequestParam(required=false)Integer allocationNo){return references.candidates(id,sourceFingerprint,expectedClaimId,styleId,auxiliaryId,employeeId,kind,accountingAsOf,search,entryId,allocationNo);}
    @GetMapping("/payroll-gl-sources/page") public Map<String,Object> candidatesPage(@PathVariable UUID id,@RequestParam String sourceFingerprint,@RequestParam UUID expectedClaimId,@RequestParam UUID styleId,@RequestParam(required=false)UUID auxiliaryId,@RequestParam(required=false)UUID employeeId,@RequestParam String kind,@RequestParam LocalDate accountingAsOf,@RequestParam(required=false)String search,@RequestParam(required=false)UUID entryId,@RequestParam(required=false)Integer allocationNo,@RequestParam(defaultValue="1")int page,@RequestParam(defaultValue="100")int size){return references.candidatesPage(id,sourceFingerprint,expectedClaimId,styleId,auxiliaryId,employeeId,kind,accountingAsOf,search,entryId,allocationNo,page,size);}
}
