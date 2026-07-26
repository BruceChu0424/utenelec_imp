package com.uten.imp.features.sales.quote;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import java.util.List;
import java.util.UUID;

/** 销售报价明细仓库（明细独立管理，不走主表 @OneToMany）。 */
public interface SalesQuoteItemRepository extends JpaRepository<SalesQuoteItem, UUID> {

    List<SalesQuoteItem> findByQuoteIdOrderByLineNoAsc(UUID quoteId);

    @Modifying
    @Query("DELETE FROM SalesQuoteItem i WHERE i.quoteId = :qid")
    void deleteByQuoteId(@Param("qid") UUID quoteId);
}
