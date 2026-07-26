package com.uten.imp.features.subcontract.ret;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 委外退货单主表仓库（包名 ret 避开 Java 关键字 return）。 */
public interface SubcontractReturnRepository
        extends JpaRepository<SubcontractReturn, UUID>, JpaSpecificationExecutor<SubcontractReturn> {

    Optional<SubcontractReturn> findByLegacyId(Integer legacyId);
}
