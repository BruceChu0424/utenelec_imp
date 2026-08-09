package com.uten.imp.config.cloud;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.jdbc.datasource.lookup.AbstractRoutingDataSource;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import javax.sql.DataSource;
import java.util.Map;

/**
 * 云端读写路由数据源（仅 cloud profile 装配）。
 *
 * <p>策略（保证「永远只有本地主库可写」，零双主冲突）：
 * <ul>
 *   <li>主库健康 → 一切走 {@link #PRIMARY}（实时、一致，与 on-prem 同库）。</li>
 *   <li>主库不可达（断网）+ 只读事务 → 走 {@link #REPLICA}（陈旧但可读，授权人可看）。</li>
 *   <li>主库不可达 + 写事务 → 抛 {@link ApiException}({@link ErrorCode#PRIMARY_UNAVAILABLE}) → 503
 *       （不在云端缓存写，避免双主丢账；恢复后主库复制槽自动续传）。</li>
 * </ul>
 * 副本仅在主库宕机时承接读；正常时读也走主库，故无需会话粘性，规避 Hibernate+路由的 read-your-writes 坑。
 */
public class CloudRoutingDataSource extends AbstractRoutingDataSource {

    static final String PRIMARY = "primary";
    static final String REPLICA = "replica";

    private final PrimaryHealthIndicator health;

    public CloudRoutingDataSource(DataSource primary, DataSource replica, PrimaryHealthIndicator health) {
        this.health = health;
        setTargetDataSources(Map.of(PRIMARY, primary, REPLICA, replica));
        setDefaultTargetDataSource(primary);
    }

    @Override
    protected Object determineCurrentLookupKey() {
        if (health.isUp()) {
            return PRIMARY;
        }
        if (TransactionSynchronizationManager.isCurrentTransactionReadOnly()) {
            return REPLICA;
        }
        // 主库不可达且非只读 → 拒绝写，避免云端缓存写造成双主冲突。
        throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE);
    }
}
