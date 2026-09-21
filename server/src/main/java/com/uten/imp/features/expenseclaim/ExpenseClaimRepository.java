package com.uten.imp.features.expenseclaim;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.time.Instant;
import java.util.Collection;
import java.util.Optional;
import java.util.UUID;

public interface ExpenseClaimRepository
        extends JpaRepository<ExpenseClaim, UUID>, JpaSpecificationExecutor<ExpenseClaim> {

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("SELECT c FROM ExpenseClaim c WHERE c.id = :id")
    Optional<ExpenseClaim> findByIdForUpdate(@Param("id") UUID id);

    /** 队列汇总：[单数, 金额合计（可空）]。 */
    @Query("SELECT count(c), sum(c.totalAmount) FROM ExpenseClaim c WHERE c.status IN :statuses")
    Object[] aggregateByStatuses(@Param("statuses") Collection<String> statuses);

    /** 时间段（提交时间）汇总：[单数, 金额合计（可空）]。 */
    @Query("""
            SELECT count(c), sum(c.totalAmount) FROM ExpenseClaim c
            WHERE c.status IN :statuses
              AND c.submittedAt >= :from AND c.submittedAt < :to
            """)
    Object[] aggregateSubmittedBetween(
            @Param("statuses") Collection<String> statuses,
            @Param("from") Instant from,
            @Param("to") Instant to);

    /** 时间段（打款时间）汇总：[单数, 金额合计（可空）]。 */
    @Query("""
            SELECT count(c), sum(c.totalAmount) FROM ExpenseClaim c
            WHERE c.status = 'PAID' AND c.paidAt >= :from AND c.paidAt < :to
            """)
    Object[] aggregatePaidBetween(@Param("from") Instant from, @Param("to") Instant to);

    @Query("""
            SELECT count(c), sum(c.totalAmount) FROM ExpenseClaim c
            WHERE c.status IN :statuses AND c.applicantId<>:actor
            AND (:payment=false OR c.approvedBy IS NULL OR c.approvedBy<>:actor)
            """)
    Object[] aggregateActionable(@Param("statuses") Collection<String> statuses,
        @Param("actor") UUID actor,@Param("payment") boolean payment);

    @Query("""
        SELECT count(c),sum(c.totalAmount) FROM ExpenseClaim c
        WHERE c.submittedAt>=:from AND c.submittedAt<:to
          AND ((:approve=true AND (c.status IN ('SUBMITTED','REVIEWING') OR c.approvedBy=:actor OR c.rejectedBy=:actor))
               OR (:pay=true AND c.status IN ('APPROVED','PAID')))
        """)
    Object[] aggregateSubmittedVisible(@Param("from") Instant from,@Param("to") Instant to,
        @Param("actor") UUID actor,@Param("approve") boolean approve,@Param("pay") boolean pay);
}
