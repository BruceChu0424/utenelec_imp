package com.uten.imp.config.cloud;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import javax.sql.DataSource;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;

/**
 * 云端读写路由决策单测（不需要 Spring 上下文 / 真实 DB）。
 * 验证「永远只有本地主库可写」：主库健康→主库；断网只读→副本；断网写/无事务→503。
 */
class CloudRoutingDataSourceTest {

    private final DataSource primary = mock(DataSource.class);
    private final DataSource replica = mock(DataSource.class);
    private final PrimaryHealthIndicator health = new PrimaryHealthIndicator(primary);

    @AfterEach
    void clearTx() {
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.clear();
        }
    }

    @Test
    void primaryUp_alwaysRoutesToPrimary() {
        CloudRoutingDataSource ds = new CloudRoutingDataSource(primary, replica, health);
        health.setUp(true);
        // 无事务：健康 → 主库
        assertEquals(CloudRoutingDataSource.PRIMARY, ds.determineCurrentLookupKey());
        // 只读事务：健康 → 仍主库（正常时读不走副本，规避 read-your-writes）
        beginReadOnlyTx();
        assertEquals(CloudRoutingDataSource.PRIMARY, ds.determineCurrentLookupKey());
    }

    @Test
    void primaryDown_readOnlyRoutesToReplica() {
        CloudRoutingDataSource ds = new CloudRoutingDataSource(primary, replica, health);
        health.setUp(false);
        beginReadOnlyTx();
        assertEquals(CloudRoutingDataSource.REPLICA, ds.determineCurrentLookupKey());
    }

    @Test
    void primaryDown_writeTxRejectedWith503() {
        CloudRoutingDataSource ds = new CloudRoutingDataSource(primary, replica, health);
        health.setUp(false);
        beginWriteTx();
        ApiException ex = assertThrows(ApiException.class, ds::determineCurrentLookupKey);
        assertEquals(ErrorCode.PRIMARY_UNAVAILABLE, ex.getCode());
    }

    @Test
    void primaryDown_noTransactionRejectedWith503() {
        CloudRoutingDataSource ds = new CloudRoutingDataSource(primary, replica, health);
        health.setUp(false);
        // 无活动事务视为写 → 拒绝（避免在副本上误写）
        ApiException ex = assertThrows(ApiException.class, ds::determineCurrentLookupKey);
        assertEquals(ErrorCode.PRIMARY_UNAVAILABLE, ex.getCode());
    }

    private void beginReadOnlyTx() {
        TransactionSynchronizationManager.initSynchronization();
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
    }

    private void beginWriteTx() {
        TransactionSynchronizationManager.initSynchronization();
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(false);
    }
}
