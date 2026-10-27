package com.uten.imp.features.purchase.order;

import jakarta.validation.Valid;
import jakarta.validation.constraints.*;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import java.util.*;

@RestController
public class PurchasePrintAuthorizationController {
    private final PurchasePrintAuthorizationService service;
    public PurchasePrintAuthorizationController(PurchasePrintAuthorizationService service){this.service=service;}
    public record DocumentProof(@NotNull UUID id,@NotNull @Pattern(regexp="[0-9a-f]{64}") String contentDigest) { }
    @com.fasterxml.jackson.annotation.JsonPropertyOrder({"documents"})
    public static final class Request {
        @NotEmpty @Size(max=100)
        private final List<@NotNull @Valid DocumentProof> documents;

        @com.fasterxml.jackson.annotation.JsonCreator
        public Request(@com.fasterxml.jackson.annotation.JsonProperty("documents")
                @NotEmpty @Size(max=100) List<@NotNull @Valid DocumentProof> documents) {
            this.documents = documents == null ? null : Collections.unmodifiableList(new ArrayList<>(documents));
        }

        @com.fasterxml.jackson.annotation.JsonProperty("documents")
        @NotEmpty @Size(max=100)
        public List<@NotNull @Valid DocumentProof> documents() {
            return documents == null ? null : Collections.unmodifiableList(documents);
        }

        @Override public boolean equals(Object other) {
            return this == other || other instanceof Request that && Objects.equals(documents, that.documents);
        }

        @Override public int hashCode() { return Objects.hashCode(documents); }

        @Override public String toString() {
            return "Request[documents=" + documents + "]";
        }
    }
    @PostMapping("/api/purchase/orders/print-authorization")
    @PreAuthorize("hasAnyAuthority('purchase_order:view','finance_order_approval:view')")
    @com.uten.imp.security.StepUpExempt("只读核对原采购打印快照；沿原print-data权限与内容摘要")
    @com.uten.imp.audit.AuditedRead("核对已生成的采购打印快照，授权完成不等于文件已交付")
    public ResponseEntity<Void> authorize(@Valid @RequestBody Request request,jakarta.servlet.http.HttpServletRequest servlet){
        com.uten.imp.audit.AuditRequestContext.markControlledRead(servlet);
        service.authorize(request.documents());return ResponseEntity.noContent().build();
    }
}
