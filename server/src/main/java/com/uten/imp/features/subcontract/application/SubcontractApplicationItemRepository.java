package com.uten.imp.features.subcontract.application;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 委外申请明细仓库。明细独立管理（不走主表 @OneToMany，规避软删+cascade 坑）。 */
public interface SubcontractApplicationItemRepository extends JpaRepository<SubcontractApplicationItem, UUID> {

    List<SubcontractApplicationItem> findByApplicationIdOrderByLineNoAsc(UUID applicationId);

    @Modifying
    @Query("DELETE FROM SubcontractApplicationItem i WHERE i.applicationId = :aid")
    void deleteByApplicationId(@Param("aid") UUID applicationId);
}
