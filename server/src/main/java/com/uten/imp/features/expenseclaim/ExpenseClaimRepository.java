package com.uten.imp.features.expenseclaim;

import jakarta.persistence.LockModeType;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.Optional;
import java.util.UUID;

public interface ExpenseClaimRepository
        extends JpaRepository<ExpenseClaim, UUID>, JpaSpecificationExecutor<ExpenseClaim> {

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("SELECT c FROM ExpenseClaim c WHERE c.id = :id")
    Optional<ExpenseClaim> findByIdForUpdate(@Param("id") UUID id);
}
