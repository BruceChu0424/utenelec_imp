package com.uten.imp.features.expenseclaim;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface ExpenseClaimInvoiceRepository
        extends JpaRepository<ExpenseClaimInvoice, UUID> {

    List<ExpenseClaimInvoice> findByClaimIdOrderByLineNoAsc(UUID claimId);

    /** 下一行号（新建发票行用；空表从 1 起）。 */
    @Query("SELECT coalesce(max(i.lineNo), 0) + 1 FROM ExpenseClaimInvoice i WHERE i.claimId = :claimId")
    int nextLineNo(@Param("claimId") UUID claimId);

    /**
     * 防重复报销查重（财会〔2020〕6 号）：按「代码（可空）+号码」找其它存活报销单上的
     * 同一张票。代码空 = 数电票（20 位号码全国唯一）；老票按代码+号码联合定位。
     */
    @Query(value = """
            SELECT i.claim_id, c.claim_no, c.status, c.applicant_name_snapshot
            FROM expense_claim_invoices i JOIN expense_claims c ON c.id=i.claim_id
            WHERE i.invoice_no=:invoiceNo AND coalesce(i.invoice_code,'')=coalesce(:invoiceCode,'')
              AND (CASE WHEN i.invoice_type='OTHER' AND NOT ((i.invoice_no ~ '^[0-9]{20}$' AND i.invoice_code IS NULL) OR (i.invoice_no ~ '^[0-9]{8}$' AND coalesce(i.invoice_code,'') ~ '^([0-9]{10}|[0-9]{12})$')) THEN upper(btrim(i.seller_name)) ELSE '' END)=:issuer
              AND (CAST(:excludeClaimId AS uuid) IS NULL OR i.claim_id<>:excludeClaimId)
            LIMIT 1
            """,nativeQuery=true)
    Optional<Object[]> findDuplicateHolder(@Param("invoiceNo") String invoiceNo,
        @Param("invoiceCode") String invoiceCode,@Param("excludeClaimId") UUID excludeClaimId,@Param("issuer") String issuer);

    @Query(value="""
            SELECT i.id FROM expense_claim_invoices i
            WHERE i.invoice_no=:invoiceNo AND coalesce(i.invoice_code,'')=coalesce(:invoiceCode,'')
            AND (CASE WHEN i.invoice_type='OTHER' AND NOT ((i.invoice_no ~ '^[0-9]{20}$' AND i.invoice_code IS NULL) OR (i.invoice_no ~ '^[0-9]{8}$' AND coalesce(i.invoice_code,'') ~ '^([0-9]{10}|[0-9]{12})$')) THEN upper(btrim(i.seller_name)) ELSE '' END)=:issuer
            AND (CAST(:excludeInvoiceId AS uuid) IS NULL OR i.id<>:excludeInvoiceId)
            LIMIT 1
            """,nativeQuery=true)
    Optional<UUID> duplicateInvoice(@Param("invoiceNo") String invoiceNo,
        @Param("invoiceCode") String invoiceCode, @Param("excludeInvoiceId") UUID excludeInvoiceId,@Param("issuer") String issuer);
}
