package com.uten.imp.features.subcontract.waste;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 委外损耗明细仓库。明细独立管理（不走主表 @OneToMany）。 */
public interface SubcontractWasteItemRepository extends JpaRepository<SubcontractWasteItem, UUID> {

    List<SubcontractWasteItem> findByWasteIdOrderByLineNoAsc(UUID wasteId);

    @Modifying
    @Query("DELETE FROM SubcontractWasteItem i WHERE i.wasteId = :wid")
    void deleteByWasteId(@Param("wid") UUID wasteId);
}
