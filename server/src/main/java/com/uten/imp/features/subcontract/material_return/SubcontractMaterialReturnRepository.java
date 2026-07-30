package com.uten.imp.features.subcontract.material_return;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 委外材料退货单主表仓库。 */
public interface SubcontractMaterialReturnRepository
        extends JpaRepository<SubcontractMaterialReturn, UUID>, JpaSpecificationExecutor<SubcontractMaterialReturn> {

    Optional<SubcontractMaterialReturn> findByLegacyId(Integer legacyId);
}
