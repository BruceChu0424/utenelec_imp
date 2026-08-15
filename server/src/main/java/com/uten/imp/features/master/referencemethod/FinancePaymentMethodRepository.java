package com.uten.imp.features.master.referencemethod;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface FinancePaymentMethodRepository extends JpaRepository<FinancePaymentMethod, UUID> {
    List<FinancePaymentMethod> findByLegacyNameConfirmedTrueAndStatusAndDeletedFalseOrderBySortOrderAscCodeAsc(
            String status);
}
