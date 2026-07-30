package com.uten.imp.features.subcontract.material_return;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 委外材料退明细仓库。明细独立管理（不走主表 @OneToMany）。 */
public interface SubcontractMaterialReturnItemRepository extends JpaRepository<SubcontractMaterialReturnItem, UUID> {

    List<SubcontractMaterialReturnItem> findByMaterialReturnIdOrderByLineNoAsc(UUID materialReturnId);

    @Modifying
    @Query("DELETE FROM SubcontractMaterialReturnItem i WHERE i.materialReturnId = :rid")
    void deleteByMaterialReturnId(@Param("rid") UUID materialReturnId);
}
