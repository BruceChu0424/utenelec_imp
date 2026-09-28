package com.uten.imp.features.stock.ledger;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Set;

/**
 * 流水往来方 (客户/供应商/委外商/车间) 名称的可见性。
 *
 * <p>流水接口只要 stock:view (几乎全员), 而来源单据按各自模块权限把关 (采购收货要 purchase_receipt:view 等),
 * 所以往来方名称只给持有「能打开该来源单据」任一权限的人 ({@link StockLedgerSource#viewAuthorities()});
 * 没登记的来源、取不到当前用户时一律遮住 (fail closed, 同 StockCostMasker)。单号照常显示, 点开时由来源页
 * 自己的权限再把一次关。调拨的对方仓库是内部信息, 不遮。
 */
@Component
@RequiredArgsConstructor
public class StockLedgerSourceAccess {

    private final SecurityContextCurrentUser currentUser;

    /** 当前用户的权限快照 (一次请求取一次, 逐行判断用 {@link #canSeeCounterpart})。 */
    public Set<String> currentAuthorities() {
        return currentUser.get().map(AuthUser::getPermissions).<Set<String>>map(Set::copyOf).orElse(Set.of());
    }

    /**
     * @param sourceDocType   流水的 source_doc_type
     * @param counterpartKind 往来方种类 ({@link StockLedgerSource.CounterpartKind} 名)
     * @param authorities     当前用户权限
     */
    public static boolean canSeeCounterpart(String sourceDocType, String counterpartKind, Set<String> authorities) {
        if (StockLedgerSource.CounterpartKind.WAREHOUSE.name().equals(counterpartKind)) {
            return true;
        }
        if (authorities == null || authorities.isEmpty()) {
            return false;
        }
        return StockLedgerSource.of(sourceDocType)
                .map(source -> source.viewAuthorities().stream().anyMatch(authorities::contains))
                .orElse(false);
    }
}
