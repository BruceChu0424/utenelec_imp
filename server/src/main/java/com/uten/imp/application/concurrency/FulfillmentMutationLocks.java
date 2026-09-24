package com.uten.imp.application.concurrency;

import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialSource;
import com.uten.imp.application.concurrency.FulfillmentMutationLockPlan.CommercialType;
import com.uten.imp.application.port.InventoryMutationPort;
import jakarta.persistence.EntityManager;
import org.hibernate.Session;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.sql.SQLException;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;

/**
 * Commercial heads/items -> complete inventory -> main warehouses -> analyses.
 *
 * <p>ADR-107: 以事务为单位「一轮发现 + 一次版本复核」。事务里第一次 {@link #acquire} 跑一轮只读发现
 * (子足迹按方法+参数去重、分析并集只展开一次)并按偏序拿齐锁; 取锁的命令在锁住执行对象、第一笔写
 * 之前调用守卫的 {@link Guard#verifyUnchanged()}, 再读一轮比对各行 {@code (id, xmin)} 行版本与行集合
 * (新增/消失的行都会让集合不等), 不再对整行做哈希。之后的嵌套 acquire 不再发现, 只对调用方声明的
 * 已知 id 做纯内存覆盖检查; 若取锁的命令从没复核就进入了嵌套命令(只为给嵌套出库预锁的入口),
 * 第一个嵌套 acquire 替它做一次锁后覆盖复核(重读取锁命令自己的发现, 结果必须仍落在已持有集合内)。</p>
 *
 * <p>嵌套命令自己的完整足迹在生产配置下<b>不再</b>于运行期重新发现: 没声明的商业来源、主仓在嵌套时
 * 没有运行期检查, 由各实际加锁入口的内存检查(库存维度、分析头)和测试里打开的
 * {@code uten.concurrency.verify-nested-footprint}(嵌套 acquire 重跑本命令的发现并要求被覆盖)兜底。</p>
 */
@Component
public class FulfillmentMutationLocks {
    public static final String WAREHOUSE_BUSY_MESSAGE = "有人正在处理同一仓库的单据，请稍后再试";
    public static final String SOURCE_BUSY_MESSAGE = "有人正在处理相关单据，本次操作未生效，请稍后再试";
    /** PostgreSQL 等锁超过 lock_timeout。 */
    private static final String LOCK_NOT_AVAILABLE = "55P03";

    private final EntityManager em;
    private final InventoryMutationPort inventory;
    /** 开发/测试诊断开关: 嵌套 acquire 也重跑本命令的发现并要求落在预锁集合内(生产关闭)。 */
    private final boolean verifyNestedFootprint;

    public FulfillmentMutationLocks(EntityManager em, InventoryMutationPort inventory) {
        this(em, inventory, false);
    }

    @Autowired
    public FulfillmentMutationLocks(EntityManager em, InventoryMutationPort inventory,
            @Value("${uten.concurrency.verify-nested-footprint:false}") boolean verifyNestedFootprint) {
        this.em = em;
        this.inventory = inventory;
        this.verifyNestedFootprint = verifyNestedFootprint;
    }

    /** Discovery is read-only. Caller keeps existing plan/package/segment/physical row locks after this prefix. */
    @Transactional(propagation = Propagation.MANDATORY)
    public Guard acquire(Supplier<FulfillmentMutationLockPlan> discovery) {
        return acquire(FulfillmentMutationLockPlan.nothingDeclared(), discovery);
    }

    /**
     * @param declared 嵌套时(本事务已持有完整预锁)要检查覆盖的已知 id; 只在内存里比较。
     * @param discovery 本事务第一次预锁时的只读发现; 嵌套时不执行(打开诊断开关时除外)。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public Guard acquire(FulfillmentMutationLockPlan declared, Supplier<FulfillmentMutationLockPlan> discovery) {
        Objects.requireNonNull(declared);
        Objects.requireNonNull(discovery);
        FulfillmentLockState.State state = state();
        if (state.prepared) {
            requireCovered(declared);
            if (!state.prefixRechecked) recheckPrefixCoverage(state);
            if (verifyNestedFootprint) requireDiscoveredCovered(discovery);
            return new Guard(state, false);
        }
        if (state.inventoryEntered) {
            throw FulfillmentLockState.conflict("已进入库存锁阶段，不能再补商业来源前缀，请刷新后重试");
        }
        FulfillmentMutationLockPlan plan = FulfillmentDiscoveryRound.discover(discovery);
        try {
            lockPrefix(state, plan, discovery);
        } catch (RuntimeException failure) {
            if (failure instanceof FulfillmentSourceConflictException || !lockTimedOut(failure)) throw failure;
            // 预锁阶段排在别人后面超过 lock_timeout: 本命令还没写任何东西, 与主仓锁等不到同样处理——
            // 可重跑 409, 由最外层事务边界在重跑预算内再排一次队。
            throw new FulfillmentSourceConflictException("预锁等锁超过 lock_timeout: " + plan.fingerprint(), true,
                    SOURCE_BUSY_MESSAGE);
        }
        return new Guard(state, true);
    }

    private void lockPrefix(FulfillmentLockState.State state, FulfillmentMutationLockPlan plan,
            Supplier<FulfillmentMutationLockPlan> discovery) {
        // Every source head precedes every source item, including shared request/application sources.
        for (CommercialType type : CommercialType.values()) {
            List<UUID> ids = sourceIds(plan, type);
            if (ids.isEmpty()) continue;
            List<?> rows = em.createNativeQuery("SELECT id FROM " + type.headerTable
                    + " WHERE id IN (:ids) ORDER BY id FOR UPDATE")
                    .setParameter("ids", ids).getResultList();
            if (rows.size() != ids.size()) throw FulfillmentLockState.conflict("商业来源已不存在，请刷新后重试");
        }
        for (CommercialType type : CommercialType.values()) {
            List<UUID> ids = sourceIds(plan, type);
            if (!ids.isEmpty()) em.createNativeQuery("SELECT id FROM " + type.itemTable
                    + " WHERE " + type.parentColumn + " IN (:ids) ORDER BY " + type.parentColumn + ",id FOR UPDATE")
                    .setParameter("ids", ids).getResultList();
        }
        state.sources.addAll(plan.commercialSources());
        state.inventory.addAll(plan.inventoryDimensions());
        state.prepared = true;
        state.prefixPlan = plan;
        state.prefixDiscovery = discovery;
        state.prefixVerified = false;
        state.prefixRechecked = false;
        // Freeze the declared inventory set even for a source-only command.
        inventory.lockDimensions(plan.inventoryDimensions().stream().sorted().toList());
        state.inventoryEntered = true;
        lockMainWarehouses(state, plan.mainWarehouseIds());
        state.warehouses.addAll(plan.mainWarehouseIds());
        if (!plan.analysisIds().isEmpty()) {
            List<?> rows = em.createNativeQuery("""
                    SELECT id FROM production_material_analyses
                    WHERE id IN (:ids) ORDER BY id FOR UPDATE
                    """).setParameter("ids", sorted(plan.analysisIds())).getResultList();
            if (rows.size() != plan.analysisIds().size()) {
                throw FulfillmentLockState.conflict("关联物料分析已不存在，请刷新后重试");
            }
        }
        state.analyses.addAll(plan.analysisIds());
    }

    /** 沿异常链找 PostgreSQL 等锁超时(lock_timeout)。 */
    private static boolean lockTimedOut(Throwable failure) {
        int depth = 0;
        for (Throwable cause = failure; cause != null && depth < 16; cause = cause.getCause(), depth++) {
            if (cause instanceof SQLException sql && LOCK_NOT_AVAILABLE.equals(sql.getSQLState())) return true;
        }
        return false;
    }

    /**
     * For callbacks after their own writes: only coverage, never the pre-write status fingerprint.
     * 纯内存比较调用方<b>声明的已知 id</b>; 超出集合是足迹声明缺口, 不可重跑并记 ERROR。
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireCovered(FulfillmentMutationLockPlan needed) {
        FulfillmentLockState.State state = preparedState();
        Set<Object> missing = missing(state, needed);
        if (!missing.isEmpty()) {
            throw FulfillmentLockState.coverageGap("回调来源超出本次完整预锁集合(" + needed.fingerprint()
                    + ")，缺少 " + missing);
        }
    }

    /** 物料分析头(以及它在预锁时已展开的来源/库存/主仓)已在本事务的预锁集合里。 */
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireAnalysesCovered(Collection<UUID> analysisIds) {
        requireCovered(FulfillmentMutationLockPlan.declaredAnalyses(analysisIds));
    }

    /**
     * 写后回调在调用方拿不出已知 id 时的覆盖检查: 跑一轮(去重的)只读发现, 结果必须落在已持有集合内。
     * 能声明已知 id 的调用方应改用 {@link #requireCovered}, 不读库。
     *
     * <p>发现会读到预锁没锁住的依赖(例如计划 BOM 递归), 别的事务在预读之后改了它们也会超出集合,
     * 所以这里的缺口按可重跑冲突处理(记 WARN), 与按声明 id 的内存检查区分开。</p>
     */
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireDiscoveredCovered(Supplier<FulfillmentMutationLockPlan> discovery) {
        FulfillmentLockState.State state = preparedState();
        FulfillmentMutationLockPlan needed = FulfillmentDiscoveryRound.discover(discovery);
        Set<Object> missing = missing(state, needed);
        if (!missing.isEmpty()) {
            throw FulfillmentLockState.discoveredCoverageGap("重新发现的来源超出本次完整预锁集合("
                    + needed.fingerprint() + ")，缺少 " + missing);
        }
    }

    private FulfillmentLockState.State preparedState() {
        FulfillmentLockState.State state = state();
        if (!state.prepared) {
            throw FulfillmentLockState.coverageGap("本事务尚未取得完整预锁，不能直接登记回调来源");
        }
        return state;
    }

    private static Set<Object> missing(FulfillmentLockState.State state, FulfillmentMutationLockPlan needed) {
        Set<Object> missing = new HashSet<>();
        needed.commercialSources().stream().filter(source -> !state.sources.contains(source)).forEach(missing::add);
        needed.inventoryDimensions().stream().filter(dimension -> !state.inventory.contains(dimension)).forEach(missing::add);
        needed.mainWarehouseIds().stream().filter(warehouse -> !state.warehouses.contains(warehouse))
                .map(warehouse -> "main-warehouse:" + warehouse).forEach(missing::add);
        needed.analysisIds().stream().filter(analysis -> !state.analyses.contains(analysis))
                .map(analysis -> "analysis:" + analysis).forEach(missing::add);
        return missing;
    }

    /** Call immediately before a plain INSERT of a newly generated UUID, never an upsert. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void expectCreatedSource(CommercialSource source) {
        FulfillmentLockState.State state = state();
        if (!state.prepared || exists(source.type().headerTable, source.id())) {
            throw FulfillmentLockState.conflict("新来源 UUID 必须尚不存在，已有来源必须提前预锁");
        }
        state.expectedNewSources.add(source);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void expectCreatedAnalysis(UUID id) {
        FulfillmentLockState.State state = state();
        if (!state.prepared || exists("production_material_analyses", id)) {
            throw FulfillmentLockState.conflict("新分析 UUID 必须尚不存在，已有分析必须提前预锁");
        }
        state.expectedNewAnalyses.add(id);
    }

    /** The new row must be written by this transaction after its prior non-existence was confirmed. */
    @Transactional(propagation = Propagation.MANDATORY)
    public void registerCreatedSource(CommercialSource source) {
        FulfillmentLockState.State state = state();
        if (!state.prepared || !state.expectedNewSources.contains(source)
                || !createdHere(source.type().headerTable, source.id())) {
            throw FulfillmentLockState.conflict("只能登记本事务新建的商业来源，已有来源必须提前预锁");
        }
        state.sources.add(source);
        state.expectedNewSources.remove(source);
    }

    @Transactional(propagation = Propagation.MANDATORY)
    public void registerCreatedAnalysis(UUID analysisId, UUID mainWarehouseId) {
        FulfillmentLockState.State state = state();
        if (!state.prepared || !state.expectedNewAnalyses.contains(analysisId)
                || !state.warehouses.contains(mainWarehouseId)
                || !createdHere("production_material_analyses", analysisId)) {
            throw FulfillmentLockState.conflict("只能在已锁主仓登记本事务新建分析，已有分析必须提前预锁");
        }
        state.analyses.add(analysisId);
        state.expectedNewAnalyses.remove(analysisId);
    }

    private boolean exists(String table, UUID id) {
        return Boolean.TRUE.equals(em.createNativeQuery("SELECT EXISTS (SELECT 1 FROM " + table + " WHERE id=:id)")
                .setParameter("id", id).getSingleResult());
    }

    /**
     * 行版本属于本事务(xmin = 当前事务号)。配合 {@link #expectCreatedSource} 先确认该 UUID
     * 尚不存在、调用方只做普通 INSERT(主键唯一约束拒绝并发插入的同一 UUID), 足以证明是本事务新建;
     * 不再依赖审计日志(审计有保留期、可能只记变化列, 不能当事实源, db-schema-02)。
     */
    private boolean createdHere(String table, UUID id) {
        return Boolean.TRUE.equals(em.createNativeQuery("SELECT EXISTS (SELECT 1 FROM " + table
                + " WHERE id=:id AND xmin::text::numeric = mod(pg_current_xact_id()::text::numeric,4294967296))")
                .setParameter("id", id).getSingleResult());
    }

    /**
     * 主仓协调锁仍是阻塞式咨询锁: 在锁管理器里排队(大致先来先得), 死锁由数据库检测。等待上限就是
     * 连接上的 lock_timeout(应用连接默认 10 秒, 见 uten.database.lock-timeout; 后台任务可在自己的事务里
     * 调短), 到点拿不到回可重跑 409「有人正在处理同一仓库的单据」。物料分析下达预览自 ADR-116 起
     * 是只读投影, 不再取这把锁。
     *
     * <p>走 JDBC 直接执行并在这里接住等锁超时: 不经 JPA 查询异常转换, Hibernate 不会把事务标成只能回滚
     * (数据库事务已因这条语句出错而作废, 调用方的保存点回滚仍能照常恢复)。</p>
     */
    private void lockMainWarehouses(FulfillmentLockState.State state, Collection<UUID> mainWarehouses) {
        String sql = "SELECT pg_advisory_xact_lock(hashtextextended(?,0))";
        for (UUID warehouse : sorted(mainWarehouses)) {
            String key = "MATERIAL-ANALYSIS-WAREHOUSE:" + warehouse;
            boolean acquired = em.unwrap(Session.class).doReturningWork(connection -> {
                try (var statement = connection.prepareStatement(sql)) {
                    statement.setString(1, key);
                    statement.executeQuery().close();
                    return true;
                } catch (SQLException failure) {
                    if (LOCK_NOT_AVAILABLE.equals(failure.getSQLState())) return false;
                    throw failure;
                }
            });
            if (!acquired) {
                throw new FulfillmentSourceConflictException(
                        "主仓协调锁等待超过 lock_timeout: " + warehouse, true, WAREHOUSE_BUSY_MESSAGE);
            }
        }
    }

    private void verifyPrefixOnce(FulfillmentLockState.State state) {
        if (state.prefixVerified) return;
        // 等锁期间别的事务先提交(同一订货单的另一张收货单、同一分析的另一条供给),
        // 本事务预读的来源集合已经过期: 这里还没写任何东西, 拒绝后由最外层事务边界
        // 用同一请求自动重跑(重新预读 + 重新按序拿锁), 客户端不必手工重试。
        FulfillmentMutationLockPlan current = FulfillmentDiscoveryRound.discover(state.prefixDiscovery);
        if (!state.prefixPlan.equals(current)) {
            throw FulfillmentLockState.retryableConflict("来源集合在预读后变化，请刷新并重新提交；本次未补拿新锁");
        }
        state.prefixVerified = true;
        state.prefixRechecked = true;
    }

    /**
     * 取锁的命令没复核就进入嵌套命令时的锁后复核: 这时它可能已经写过(例如先改了执行段再就地出库),
     * 行版本必然变了, 所以不比相等, 只要求重读<b>取锁命令自己的</b>足迹仍落在已持有的锁集合内——要多拿锁
     * 说明预读后依赖图被别的事务改过, 整笔回滚后由最外层自动重跑。它复核的是外层的预读,
     * 不证明嵌套命令自己的足迹被覆盖(那由声明 id 的内存检查和测试里的诊断开关负责)。
     */
    private void recheckPrefixCoverage(FulfillmentLockState.State state) {
        FulfillmentMutationLockPlan current = FulfillmentDiscoveryRound.discover(state.prefixDiscovery);
        boolean covered = state.sources.containsAll(current.commercialSources())
                && state.inventory.containsAll(current.inventoryDimensions())
                && state.warehouses.containsAll(current.mainWarehouseIds())
                && state.analyses.containsAll(current.analysisIds());
        if (!covered) {
            throw FulfillmentLockState.retryableConflict("来源集合在预读后变化，锁后复核需要未持有的来源；本次未补拿新锁");
        }
        state.prefixRechecked = true;
    }

    private FulfillmentLockState.State state() {
        if (!TransactionSynchronizationManager.isActualTransactionActive()) {
            throw new IllegalStateException("Fulfillment prelocking requires the caller's transaction");
        }
        FulfillmentLockState.State state = FulfillmentLockState.current(true);
        if (state == null || state.closed) throw new IllegalStateException("Completed transaction cannot reuse mutation locks");
        return state;
    }

    private static List<UUID> sourceIds(FulfillmentMutationLockPlan plan, CommercialType type) {
        return plan.commercialSources().stream().filter(source -> source.type() == type)
                .map(CommercialSource::id).sorted(Comparator.comparing(UUID::toString)).toList();
    }
    private static List<UUID> sorted(Collection<UUID> ids) {
        return ids.stream().distinct().sorted(Comparator.comparing(UUID::toString)).toList();
    }

    public final class Guard {
        private final FulfillmentLockState.State transaction;
        /** 取得本事务预锁的那次 acquire 的守卫; 嵌套 acquire 的守卫为假。 */
        private final boolean prefixOwner;
        private Guard(FulfillmentLockState.State transaction, boolean prefixOwner) {
            this.transaction = transaction;
            this.prefixOwner = prefixOwner;
        }
        /**
         * Invoke after locking the mutable execution/root rows, before this command's first write.
         *
         * <p>ADR-107: 整个事务只复核一次。取得预锁的守卫第一次调用时重读一轮, 与预读逐行比
         * {@code (id, xmin)}; 已经复核过的再调用不读库。嵌套 acquire 的守卫只确认仍属于当前事务、
         * 前缀没有随保存点回滚失效: 嵌套命令声明的已知 id 在 acquire 时已在内存里检查过,
         * 库存维度/分析头的实际加锁入口另有同样的内存检查。已提交的同键幂等重放可以在锁后、复核前
         * 只读返回原结果, 此时不要求预读继续相等(与原约定相同)。</p>
         */
        public void verifyUnchanged() {
            if (transaction != state()) {
                throw FulfillmentLockState.conflict("守卫与当前事务不匹配，请刷新并重新提交");
            }
            if (!transaction.prepared || transaction.prefixPlan == null) {
                throw FulfillmentLockState.conflict("预锁已随保存点回滚失效，请刷新并重新提交");
            }
            if (prefixOwner) verifyPrefixOnce(transaction);
        }
    }
}
