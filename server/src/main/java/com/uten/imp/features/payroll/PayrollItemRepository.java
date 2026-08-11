package com.uten.imp.features.payroll;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.Collection;
import java.util.List;
import java.util.UUID;

public interface PayrollItemRepository extends JpaRepository<PayrollItem, UUID> {

    List<PayrollItem> findBySlipIdInOrderBySlipIdAscLineNoAsc(Collection<UUID> slipIds);
}
