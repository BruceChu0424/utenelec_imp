package com.uten.imp.features.expenseclaim;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimCreateRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimDto;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimPaymentRequest;
import com.uten.imp.features.expenseclaim.dto.ExpenseClaimRejectRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.UUID;

/** 费用报销单接口（/api/expense-claims）。 */
@RestController
@RequestMapping("/api/expense-claims")
@RequiredArgsConstructor
public class ExpenseClaimController {

    private final ExpenseClaimService service;

    @GetMapping("/mine")
    @PreAuthorize("hasAuthority('expense:apply')")
    public PageResponse<ExpenseClaimDto> mine(
            @RequestParam(required = false) String status,
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) Integer month,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.listMine(status, year, month, departmentId, page, size);
    }

    @GetMapping("/pending")
    @PreAuthorize("hasAuthority('expense:approve')")
    public PageResponse<ExpenseClaimDto> pending(
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) Integer month,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.listPending(year, month, departmentId, page, size);
    }

    @GetMapping("/payable")
    @PreAuthorize("hasAuthority('expense:pay')")
    public PageResponse<ExpenseClaimDto> payable(
            @RequestParam(required = false) Integer year,
            @RequestParam(required = false) Integer month,
            @RequestParam(required = false) UUID departmentId,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return service.listPayable(year, month, departmentId, page, size);
    }

    @GetMapping("/{id}")
    @PreAuthorize("hasAnyAuthority('expense:apply','expense:approve','expense:pay')")
    public ExpenseClaimDto detail(@PathVariable UUID id) {
        return service.detail(id);
    }

    @PostMapping
    @PreAuthorize("hasAuthority('expense:apply')")
    public ExpenseClaimDto create(@Valid @RequestBody ExpenseClaimCreateRequest request) {
        return service.create(request);
    }

    @DeleteMapping("/{id}")
    @PreAuthorize("hasAuthority('expense:apply')")
    public void delete(@PathVariable UUID id) {
        service.delete(id);
    }

    @PostMapping("/{id}/submit")
    @PreAuthorize("hasAuthority('expense:apply')")
    public ExpenseClaimDto submit(@PathVariable UUID id) {
        return service.submit(id);
    }

    @PostMapping("/{id}/withdraw")
    @PreAuthorize("hasAuthority('expense:apply')")
    public ExpenseClaimDto withdraw(@PathVariable UUID id) {
        return service.withdraw(id);
    }

    @PostMapping("/{id}/approve")
    @PreAuthorize("hasAuthority('expense:approve')")
    public ExpenseClaimDto approve(@PathVariable UUID id) {
        return service.approve(id);
    }

    @PostMapping("/{id}/reject")
    @PreAuthorize("hasAuthority('expense:approve')")
    public ExpenseClaimDto reject(@PathVariable UUID id,
                                  @Valid @RequestBody ExpenseClaimRejectRequest request) {
        return service.reject(id, request.reason());
    }

    @PostMapping("/{id}/pay")
    @PreAuthorize("hasAuthority('expense:pay')")
    public ExpenseClaimDto pay(@PathVariable UUID id,
                               @Valid @RequestBody ExpenseClaimPaymentRequest request) {
        return service.pay(id, request);
    }
}
