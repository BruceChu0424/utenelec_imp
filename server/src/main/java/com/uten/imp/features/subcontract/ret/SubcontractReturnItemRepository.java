package com.uten.imp.features.subcontract.ret;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 委外退货明细仓库。明细独立管理（不走主表 @OneToMany）。 */
public interface SubcontractReturnItemRepository extends JpaRepository<SubcontractReturnItem, UUID> {

    List<SubcontractReturnItem> findByReturnIdOrderByLineNoAsc(UUID returnId);

    @Modifying
    @Query("DELETE FROM SubcontractReturnItem i WHERE i.returnId = :rid")
    void deleteByReturnId(@Param("rid") UUID returnId);
}
