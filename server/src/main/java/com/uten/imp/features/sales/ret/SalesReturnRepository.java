package com.uten.imp.features.sales.ret;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 销售退货单主表仓库。 */
public interface SalesReturnRepository
        extends JpaRepository<SalesReturn, UUID>, JpaSpecificationExecutor<SalesReturn> {

    Optional<SalesReturn> findByLegacyId(Integer legacyId);
}
