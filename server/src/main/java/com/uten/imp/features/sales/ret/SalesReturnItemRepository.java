package com.uten.imp.features.sales.ret;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 销售退货明细仓库。 */
public interface SalesReturnItemRepository extends JpaRepository<SalesReturnItem, UUID> {

    List<SalesReturnItem> findByReturnIdOrderByLineNoAsc(UUID returnId);

    @Modifying
    @Query("DELETE FROM SalesReturnItem i WHERE i.returnId = :rid")
    void deleteByReturnId(@Param("rid") UUID returnId);
}
