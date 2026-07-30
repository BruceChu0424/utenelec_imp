package com.uten.imp.features.subcontract.waste;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 委外材料损耗单主表仓库。 */
public interface SubcontractWasteRepository
        extends JpaRepository<SubcontractWaste, UUID>, JpaSpecificationExecutor<SubcontractWaste> {

    Optional<SubcontractWaste> findByLegacyId(Integer legacyId);
}
