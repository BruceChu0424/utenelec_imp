package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.export.ProcurementPrintAuthorization;
import com.uten.imp.security.*;
import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;

@RestController
public class SubcontractPrintAuthorizationController {
    private final SubcontractOrderPrintService print;
    private final SecurityContextCurrentUser users;
    private final ReadScopeVersionAuthority scopes;
    public SubcontractPrintAuthorizationController(SubcontractOrderPrintService print,
            SecurityContextCurrentUser users, ReadScopeVersionAuthority scopes) {
        this.print = print; this.users = users; this.scopes = scopes;
    }
    public record DocumentProof(@NotNull UUID id, @NotNull @Pattern(regexp="[0-9a-f]{64}") String contentDigest) { }
    public record Request(@NotEmpty @Size(max=100) List<@NotNull @Valid DocumentProof> documents) { }
    @PostMapping("/api/subcontract/orders/print-authorization")
    @PreAuthorize("hasAnyAuthority('subcontract_order:view','finance_order_approval:view')")
    @com.uten.imp.security.StepUpExempt("只读核对原委外打印快照；沿原print-data权限与内容摘要")
    @com.uten.imp.audit.AuditedRead("核对已生成的委外打印快照，授权完成不等于文件已交付")
    public ResponseEntity<Void> authorize(@Valid @RequestBody Request request,
            jakarta.servlet.http.HttpServletRequest servlet) {
        com.uten.imp.audit.AuditRequestContext.markControlledRead(servlet);
        ProcurementPrintAuthorization.authorize(request.documents().stream()
                .map(proof -> proof == null ? null : new ProcurementPrintAuthorization.Proof(proof.id(), proof.contentDigest())).toList(),
                "native_subcontract_owner", users, scopes, print::read);
        return ResponseEntity.noContent().build();
    }
}
