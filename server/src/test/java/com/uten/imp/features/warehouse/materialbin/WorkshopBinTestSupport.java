package com.uten.imp.features.warehouse.materialbin;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.UUID;

/**
 * 测试夹具: 开通车间内料仓(ADR-147)。与「车间内料仓」开通命令走同一条建仓路径
 * ({@link WorkshopBinService#open}), 只是不经批量命令的权限、幂等与逐车间校验。
 *
 * <p>车间直送不再第一次直送时自动建仓, 做直送的端到端测试要先开通收料车间。来源仓传测试世界的仓库,
 * 内料仓就挂在它的主仓下(测试库里可能有多个顶层仓, 直送要求内料仓与收料需求同主仓)。
 */
public final class WorkshopBinTestSupport {

    private WorkshopBinTestSupport() {}

    /** 在调用方事务里开通(已开通则原样返回); 返回内料仓 id。 */
    public static UUID open(WorkshopBinService bins, UUID workshopId, UUID sourceWarehouseId, UUID actor) {
        return bins.openedBinOf(workshopId).orElseGet(() -> bins.open(workshopId, sourceWarehouseId, actor));
    }

    /** 自己开一个事务开通(已开通则原样返回); 返回内料仓 id。 */
    public static UUID open(WorkshopBinService bins, PlatformTransactionManager transactions, UUID workshopId,
                            UUID sourceWarehouseId) {
        return new TransactionTemplate(transactions).execute(status -> open(bins, workshopId, sourceWarehouseId, null));
    }

    /**
     * 开通内料仓并挂在给定主仓下: 主仓自己就是良品子仓(测试世界只有一个仓)时以它为来源仓,
     * 否则取它下面第一个良品子仓为来源仓(内料仓挂在来源仓的主仓下)。返回内料仓 id。
     */
    public static UUID openUnderMain(WorkshopBinService bins, JdbcTemplate db, PlatformTransactionManager transactions,
                                     UUID workshopId, UUID mainWarehouseId) {
        UUID source = db.queryForObject("""
                SELECT candidate.id FROM warehouses candidate
                WHERE (candidate.id = ? OR candidate.parent_id = ?) AND fn_warehouse_is_good_stock_leaf(candidate.id)
                ORDER BY (candidate.id = ?) DESC, candidate.created_at, candidate.id
                LIMIT 1
                """, UUID.class, mainWarehouseId, mainWarehouseId, mainWarehouseId);
        return open(bins, transactions, workshopId, source);
    }
}
