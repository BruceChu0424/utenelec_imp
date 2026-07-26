package com.uten.imp.features.subcontract.application;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 委外申请单主表仓库。列表用 {@link JpaSpecificationExecutor} 动态筛选。 */
public interface SubcontractApplicationRepository
        extends JpaRepository<SubcontractApplication, UUID>, JpaSpecificationExecutor<SubcontractApplication> {

    Optional<SubcontractApplication> findByLegacyId(Integer legacyId);
}
