package com.uten.imp.features.subcontract.material_issue;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 委外发料明细仓库。明细独立管理（不走主表 @OneToMany）。 */
public interface SubcontractMaterialIssueItemRepository extends JpaRepository<SubcontractMaterialIssueItem, UUID> {

    List<SubcontractMaterialIssueItem> findByIssueIdOrderByLineNoAsc(UUID issueId);

    @Modifying
    @Query("DELETE FROM SubcontractMaterialIssueItem i WHERE i.issueId = :iid")
    void deleteByIssueId(@Param("iid") UUID issueId);
}
