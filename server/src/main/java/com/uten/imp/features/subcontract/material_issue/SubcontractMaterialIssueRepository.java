package com.uten.imp.features.subcontract.material_issue;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 委外材料出仓单主表仓库。列表用 {@link JpaSpecificationExecutor} 动态筛选。 */
public interface SubcontractMaterialIssueRepository
        extends JpaRepository<SubcontractMaterialIssue, UUID>, JpaSpecificationExecutor<SubcontractMaterialIssue> {

    Optional<SubcontractMaterialIssue> findByLegacyId(Integer legacyId);
}
