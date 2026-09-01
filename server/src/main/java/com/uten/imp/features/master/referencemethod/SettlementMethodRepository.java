package com.uten.imp.features.master.referencemethod;

import org.springframework.data.jpa.repository.JpaRepository;

import java.util.List;
import java.util.UUID;

public interface SettlementMethodRepository extends JpaRepository<SettlementMethod, UUID> {
    List<SettlementMethod> findByStatusAndDeletedFalseOrderBySortOrderAscCodeAsc(String status);

    /** 管理页全量（含禁用行；软删行仍排除）。 */
    List<SettlementMethod> findByDeletedFalseOrderBySortOrderAscCodeAsc();

    boolean existsByNameIgnoreCaseAndDeletedFalse(String name);

    boolean existsByNameIgnoreCaseAndDeletedFalseAndIdNot(String name, UUID id);
}
