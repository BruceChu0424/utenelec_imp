package com.uten.imp.features.master.referencemethod;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface SettlementMethodRepository extends JpaRepository<SettlementMethod, UUID> {
    List<SettlementMethod> findByStatusAndDeletedFalseOrderBySortOrderAscCodeAsc(String status);

    boolean existsByNameIgnoreCaseAndDeletedFalse(String name);
}
