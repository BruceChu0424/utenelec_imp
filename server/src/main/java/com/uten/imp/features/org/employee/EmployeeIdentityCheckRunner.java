package com.uten.imp.features.org.employee;

import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.security.TxSessionVars;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.boot.availability.AvailabilityChangeEvent;
import org.springframework.boot.availability.ReadinessState;
import org.springframework.context.ApplicationContext;
import org.springframework.core.annotation.Order;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.List;
import java.util.Objects;
import java.util.Optional;
import java.util.UUID;

/**
 * V798 启动回填：把还是 {@code unchecked} 的证件号 (老库人事导入写进来的) 解密后判定一次，
 * 写回 {@code employee_sensitive.id_card_check}；解不开的密文存 {@code unreadable}，以后启动不再重试。
 *
 * <p>数据库拿不到解密密钥，所以只能在 JVM 里做。和 V282 回填任务、老库人事导入脚本共用同一把
 * advisory lock，互不交叉。按 employee_id 键集分页 (万一有行没能离开 unchecked，也不会原地打转)，
 * 每批一个短事务，逐行用 {@link TxSessionVars#tryDecrypt}：解密在保存点里执行，某一行解不开只回滚到
 * 保存点，本批事务照常可用，也不经 Hibernate 报 ERROR 日志。</p>
 *
 * <p>和 V282 不同，这里没有丢数据的风险，解不开不阻止启动：这些行在人事任务、开号就绪检查、
 * 员工详情和开号结果里都显示为「档案里的证件号码读取不出来」，人事对照证件重新登记一次号码即可结案
 * (写入口随新密文改写校验结果)。如果是换密钥后没配旧密钥造成的，配好旧密钥后把这些行改回
 * {@code unchecked} 再启动一次即可重新判定。条件更新带上原密文，和并发的修改证件互不覆盖。
 * 日志只写数量 (有解不开的行时一条 WARN 汇总)，绝不写号码、后四位或姓名。</p>
 */
@Component
@Order(61)
public class EmployeeIdentityCheckRunner implements ApplicationRunner {

    private static final Logger log = LoggerFactory.getLogger(EmployeeIdentityCheckRunner.class);
    private static final int BATCH_SIZE = 100;
    /** 与 EmployeePiiExtraBackfillRunner、老库人事导入脚本同一把锁：ASCII "UTEN" + 282。 */
    private static final int ADVISORY_LOCK_NAMESPACE = 0x5554454E;
    private static final int ADVISORY_LOCK_ID = 282;
    private static final UUID KEYSET_START = new UUID(0L, 0L);

    private final JdbcTemplate jdbc;
    private final TxSessionVars tx;
    private final TransactionTemplate transactionTemplate;
    private final ApplicationContext applicationContext;

    public EmployeeIdentityCheckRunner(
            JdbcTemplate jdbc,
            TxSessionVars tx,
            PlatformTransactionManager transactionManager,
            ApplicationContext applicationContext) {
        this.jdbc = jdbc;
        this.tx = tx;
        this.transactionTemplate = new TransactionTemplate(transactionManager);
        this.applicationContext = applicationContext;
    }

    @Override
    public void run(ApplicationArguments args) {
        AvailabilityChangeEvent.publish(applicationContext, ReadinessState.REFUSING_TRAFFIC);
        withGlobalMigrationLock(this::checkLocked);
    }

    private void checkLocked() {
        Tally tally = new Tally();
        UUID after = KEYSET_START;
        while (true) {
            List<PendingIdentity> batch = nextBatch(after);
            if (batch.isEmpty()) {
                break;
            }
            checkBatch(batch, tally);
            after = batch.get(batch.size() - 1).employeeId();
        }
        if (tally.unreadable > 0) {
            log.warn("Employee identity check backfill: valid={}, problem={}, unreadable={}, changedConcurrently={}; "
                            + "unreadable identity numbers are stored as unreadable and listed for HR to re-enter",
                    tally.valid, tally.problem, tally.unreadable, tally.skipped);
        } else if (tally.total() > 0) {
            log.info("Employee identity check backfill: valid={}, problem={}, unreadable={}, changedConcurrently={}",
                    tally.valid, tally.problem, tally.unreadable, tally.skipped);
        }
    }

    private List<PendingIdentity> nextBatch(UUID after) {
        return jdbc.query(
                """
                SELECT s.employee_id, e.id_type, s.id_card_enc
                FROM employee_sensitive s
                JOIN employees e ON e.id = s.employee_id
                WHERE s.id_card_check = 'unchecked'
                  AND s.employee_id > ?
                ORDER BY s.employee_id
                LIMIT ?
                """,
                statement -> {
                    statement.setObject(1, after);
                    statement.setInt(2, BATCH_SIZE);
                },
                (result, rowNumber) -> new PendingIdentity(
                        result.getObject("employee_id", UUID.class),
                        result.getString("id_type"),
                        result.getString("id_card_enc")));
    }

    private void checkBatch(List<PendingIdentity> batch, Tally tally) {
        Tally batchTally = transactionTemplate.execute(status -> {
            Tally local = new Tally();
            for (PendingIdentity row : batch) {
                // 解不开 (数据损坏、密钥版本不在密钥环里) 时为空；保存点里失败，不作废本批事务。
                Optional<String> plain = tx.tryDecrypt(row.cipher());
                String check = plain
                        .map(value -> EmployeeIdentityCheck.classify(row.idType(), IdCardUtil.normalize(value)))
                        .orElse(EmployeeIdentityCheck.UNREADABLE);
                store(row, check, local);
            }
            return local;
        });
        tally.add(Objects.requireNonNull(batchTally));
    }

    private void store(PendingIdentity row, String check, Tally tally) {
        int updated = jdbc.update(
                """
                UPDATE employee_sensitive
                SET id_card_check = ?
                WHERE employee_id = ?
                  AND id_card_check = 'unchecked'
                  AND id_card_enc = ?
                """,
                check, row.employeeId(), row.cipher());
        if (updated != 1) {
            // 期间被人事改过证件 (已带新结果写入)，保留对方的结果。
            tally.skipped++;
        } else if (EmployeeIdentityCheck.VALID.equals(check)) {
            tally.valid++;
        } else if (EmployeeIdentityCheck.UNREADABLE.equals(check)) {
            tally.unreadable++;
        } else {
            tally.problem++;
        }
    }

    private void withGlobalMigrationLock(Runnable action) {
        DataSource dataSource = Objects.requireNonNull(
                jdbc.getDataSource(), "JdbcTemplate has no DataSource");
        try (Connection connection = dataSource.getConnection()) {
            connection.setAutoCommit(true);
            try (PreparedStatement lock = connection.prepareStatement(
                    "SELECT pg_advisory_lock(?, ?)")) {
                lock.setInt(1, ADVISORY_LOCK_NAMESPACE);
                lock.setInt(2, ADVISORY_LOCK_ID);
                lock.executeQuery().close();
            }
            try {
                action.run();
            } finally {
                try (PreparedStatement unlock = connection.prepareStatement(
                        "SELECT pg_advisory_unlock(?, ?)")) {
                    unlock.setInt(1, ADVISORY_LOCK_NAMESPACE);
                    unlock.setInt(2, ADVISORY_LOCK_ID);
                    try (ResultSet result = unlock.executeQuery()) {
                        if (!result.next() || !result.getBoolean(1)) {
                            throw new IllegalStateException(
                                    "employee identity check advisory lock ownership was lost");
                        }
                    }
                }
            }
        } catch (SQLException exception) {
            throw new IllegalStateException(
                    "employee identity check global migration lock failed", exception);
        }
    }

    private record PendingIdentity(UUID employeeId, String idType, String cipher) {
    }

    /** 只记数量，不记任何号码或人名。 */
    private static final class Tally {
        private long valid;
        private long problem;
        private long unreadable;
        private long skipped;

        long total() {
            return valid + problem + unreadable + skipped;
        }

        void add(Tally other) {
            valid += other.valid;
            problem += other.problem;
            unreadable += other.unreadable;
            skipped += other.skipped;
        }
    }
}
