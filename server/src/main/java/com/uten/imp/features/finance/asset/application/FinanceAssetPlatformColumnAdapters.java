package com.uten.imp.features.finance.asset.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.ReadOnlyPlatformColumnAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.List;
import java.util.Set;

/** Ledger figures remain immutable; personal formulas read the same authorized summaries. */
@Configuration
@RequiredArgsConstructor
public class FinanceAssetPlatformColumnAdapters {
    private final FinanceAssetQueryService assets;private final SecurityContextCurrentUser current;private final ObjectMapper json;
    @Bean public PlatformColumnResourceAdapter financeAssetPlatformColumns() {
        return new ReadOnlyPlatformColumnAdapter("finance_asset","固定资产台账",current,json,Set.of("finance_asset:view"),Set.of("finance_asset:view"),
                id->assets.platformSummary(id,false),List.of(new FactDefinition("originalValue","原值",true),new FactDefinition("netBookValue","账面净值",true),
                    new FactDefinition("salvageRate","残值率",true),new FactDefinition("usefulMonths","使用月数",false)));
    }
    @Bean public PlatformColumnResourceAdapter financeDeferredPlatformColumns() {
        return new ReadOnlyPlatformColumnAdapter("finance_deferred_expense","长期待摊台账",current,json,Set.of("finance_asset:view"),Set.of("finance_asset:view"),
                id->assets.platformSummary(id,true),List.of(new FactDefinition("totalAmount","总金额",true),new FactDefinition("remainingAmount","剩余金额",true),
                    new FactDefinition("usefulMonths","摊销月数",false)));
    }
}
