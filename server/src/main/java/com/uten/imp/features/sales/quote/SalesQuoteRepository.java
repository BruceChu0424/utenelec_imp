package com.uten.imp.features.sales.quote;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.JpaSpecificationExecutor;

import java.util.Optional;
import java.util.UUID;

/** 销售报价单主表仓库。 */
public interface SalesQuoteRepository
        extends JpaRepository<SalesQuote, UUID>, JpaSpecificationExecutor<SalesQuote> {

    Optional<SalesQuote> findByLegacyId(Integer legacyId);

    /** 报价转入回联：按单号找来源报价（订货详情价格比对）。 */
    Optional<SalesQuote> findByBillNo(String billNo);
}
