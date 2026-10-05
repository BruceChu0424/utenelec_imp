package com.uten.imp.features.attachment;

import com.uten.imp.application.port.BusinessTestResetFilesPort;
import com.uten.imp.common.storage.InternalStorageService;
import com.uten.imp.common.storage.StorageLegacyLayoutException;
import com.uten.imp.common.storage.StorageObjectProblem;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.common.storage.StorageResourceUnavailableException;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.storage.StorageService.ObjectLocation;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.StorageProperties;
import lombok.extern.slf4j.Slf4j;
import org.postgresql.util.PSQLException;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.dao.QueryTimeoutException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionTimedOutException;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.Array;
import java.sql.SQLException;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Supplier;

/**
 * Checks and deletes the test files of "clear business data" (ADR-155). The object list comes only
 * from {@code fn_business_test_reset_objects()}; refusals the database can judge come only from
 * {@code fn_business_data_reset_refusals()}. Deleting is idempotent: absent counts as success, every
 * delete is confirmed by a second header read, and nothing is deleted while any problem is known.
 */
@Slf4j
@Service
public class BusinessTestResetFiles implements BusinessTestResetFilesPort {
    private static final int SAMPLES = 5;
    private static final String BUSY_MESSAGE = "附件读写繁忙，请稍后重试";
    private static final Set<String> CATALOG_CODES = Set.of("CATALOG_DUPLICATE", "CATALOG_UNCLASSIFIED",
            "CATALOG_MISSING", "CATALOG_PRESERVE_REFERENCES_CLEAR", "CATALOG_EXTERNAL_REFERENCE", "CATALOG_NO_TRUNCATE");
    /** Storage check problems in display order. */
    private static final List<String> PROBLEM_ORDER = List.of("STORAGE_UNAVAILABLE", "LOCAL_NOT_CONFIGURED",
            "INTERNAL_NOT_CONFIGURED", "VERSION_MISMATCH", "NOT_A_FILE", "LOCAL_LEGACY_LAYOUT", "KEY_INVALID", "READ_FAILED");
    /** Dead background event categories in display order (event type prefix, label). */
    private static final List<String[]> DEAD_EVENT_CATEGORIES = List.of(
            new String[]{"STOCK_WEIGHT_OBSERVATION_CHANGED", "货品单重重算"},
            new String[]{"PROCUREMENT_IQC_REJECTION_DETECTED", "来料检验不合格转财务"},
            new String[]{"SALES_", "销售相关"},
            new String[]{"PROCUREMENT_", "采购相关"},
            new String[]{"PRODUCTION_", "生产相关"},
            new String[]{"SUBCONTRACT_", "委外相关"},
            new String[]{"PREPLAN_", "生产计划相关"},
            new String[]{"STOCK_", "库存相关"});
    private static final String OTHER_EVENTS = "其它后台事件";

    private final JdbcTemplate jdbc;
    private final StorageProviderRegistry storage;
    private final StorageProperties properties;
    private final TransactionTemplate snapshotTx;
    private final ObjectProvider<InternalStorageService> internal;

    public BusinessTestResetFiles(JdbcTemplate jdbc, StorageProviderRegistry storage, StorageProperties properties,
                                  PlatformTransactionManager transactions, ObjectProvider<InternalStorageService> internal) {
        this.jdbc = jdbc;
        this.storage = storage;
        this.properties = properties;
        this.internal = internal;
        this.snapshotTx = new TransactionTemplate(transactions);
        snapshotTx.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        snapshotTx.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
        snapshotTx.setReadOnly(true);
        snapshotTx.setTimeout(30);
    }

    // ------------------------------------------------------------------ check (preview and before draining)

    @Override
    public Check check(Actor actor, Duration inspectionBudget) {
        Instant deadline = Instant.now().plus(inspectionBudget);
        State state = snapshotTx.execute(status -> {
            jdbc.execute("SET LOCAL lock_timeout = '5s'");
            jdbc.execute("SET LOCAL statement_timeout = '30s'");
            jdbc.queryForList("SELECT set_config('app.actor_id', ?, true), set_config('app.actor_account', ?, true), "
                            + "set_config('app.audit_request_id', ?, true)",
                    actor.id().toString(), actor.account(), UUID.randomUUID().toString());
            String waited = requireCaller("SELECT public.fn_business_test_reset_require_caller()::text");
            return readMapped(this::readState, waited);
        });
        Inspection inspection = inspect(state, deadline);
        return toCheck(state, inspection);
    }

    // ------------------------------------------------------------------ purge (inside the reset transaction)

    @Override
    public Purge purge(Instant deadline, AtomicLong deleted) {
        if (!TransactionSynchronizationManager.isActualTransactionActive()) {
            throw new IllegalStateException("Test file purge must run inside the reset transaction");
        }
        String waited = requireCaller("SELECT public.fn_business_test_reset_lock_sources()::text");
        State state = readMapped(this::readState, waited);
        String fingerprint = readMapped(() -> jdbc.queryForObject(
                "SELECT public.fn_business_test_reset_object_fingerprint()", String.class), waited);
        Inspection inspection = inspect(state, deadline);
        // A known reason (database rule, server configuration or a storage problem already found) is
        // always reported as itself; "the check ran out of time" only when there is none.
        List<Refusal> refusals = refusals(state, inspection);
        if (!refusals.isEmpty()) {
            throw BusinessTestResetFilesPort.refused(refusals);
        }
        if (!inspection.complete()) {
            throw failure(ErrorCode.CONFLICT, "INSPECTION_BUDGET", state.objects().size(), String.format(
                    "核对测试文件用完了这次的时间(已核对 %d / %d 个)，没有删除任何文件，也没有清空数据。如果服务器存储正忙，请稍后重新点「确认清空」；"
                            + "如果多次出现，说明测试文件太多(%d 个)，一次清空处理不完，请联系开发人员。",
                    inspection.inspected(), state.objects().size(), state.objects().size()));
        }
        List<Planned> toDelete = inspection.planned().stream().filter(p -> p.outcome() == Outcome.DELETE).toList();
        Instant started = Instant.now();
        Instant lastLog = started;
        for (int index = 0; index < toDelete.size(); index++) {
            Planned planned = toDelete.get(index);
            if (!Instant.now().isBefore(deadline)) {
                throw failure(ErrorCode.CONFLICT, "BUDGET", toDelete.size() - index, String.format(
                        "原因：删除测试文件用完了这次清空的时间，还有 %d 个没有删除。请重新点「确认清空」继续删除剩下的。",
                        toDelete.size() - index));
            }
            deleteAndConfirm(planned, deleted);
            Instant now = Instant.now();
            if ((index + 1) % 500 == 0 || Duration.between(lastLog, now).toSeconds() >= 10) {
                lastLog = now;
                log.info("business_data_reset 测试文件删除：已删除 {}/{}，用时 {} 秒",
                        index + 1, toDelete.size(), Duration.between(started, now).toSeconds());
            }
        }
        return new Purge(fingerprint, deleted.get(), state.deadEventTotal());
    }

    /** Deletes one object and confirms it is gone; counts it as soon as the delete returns. */
    private void deleteAndConfirm(Planned planned, AtomicLong deleted) {
        ResetObject object = planned.object();
        StorageService provider = planned.provider();
        ObjectLocation location = location(object);
        try {
            if (location == ObjectLocation.STAGING) provider.deleteStaging(object.key(), planned.version());
            else provider.delete(object.key(), planned.version());
        } catch (RuntimeException error) {
            log.warn("business_data_reset 测试文件删除失败 type={} key={}", error.getClass().getSimpleName(), keyPrefix(object.key()));
            throw failure(ErrorCode.CONFLICT, "DELETE_FAILED", 1, String.format(
                    "原因：删除%s时存储报错(%s)。请让维护人员检查服务器存储后重新点「确认清空」。",
                    object.display(), storageWords(error)));
        }
        deleted.incrementAndGet();
        StorageService.StoredObject after;
        try {
            after = inspectWithRetry(provider, location, object.key());
        } catch (RuntimeException error) {
            log.warn("business_data_reset 测试文件删除后核对失败 type={} key={}", error.getClass().getSimpleName(), keyPrefix(object.key()));
            throw failure(ErrorCode.CONFLICT, "DELETE_UNCONFIRMED", 1, String.format(
                    "原因：已删除%s，但删除后无法再次核对(存储报告：%s)。请让维护人员检查服务器存储后重新点「确认清空」。",
                    object.display(), storageWords(error)));
        }
        if (after.exists()) {
            // The delete returned but the file is still there: it was not deleted.
            deleted.decrementAndGet();
            throw failure(ErrorCode.CONFLICT, "STILL_PRESENT", 1, String.format(
                    "原因：%s删除后再次核对，仍然在存储里。请让维护人员检查服务器存储后重新点「确认清空」。", object.display()));
        }
    }

    /** One header read; a busy storage is retried a few times before its error is reported. */
    private static StorageService.StoredObject inspectWithRetry(StorageService service, ObjectLocation location, String key) {
        for (int attempt = 1; ; attempt++) {
            try {
                return service.inspectObject(location, key);
            } catch (StorageResourceUnavailableException unavailable) {
                if (!(unavailable instanceof StorageLegacyLayoutException)
                        && BUSY_MESSAGE.equals(unavailable.getMessage()) && attempt < 4) {
                    pause();
                    continue;
                }
                throw unavailable;
            }
        }
    }

    @Override
    public int cleanupAbandonedScratch() {
        InternalStorageService active = internal.getIfAvailable();
        return active == null ? 0 : active.cleanupAbandonedScratch();
    }

    // ------------------------------------------------------------------ database state

    /** deletableStorage comes from the object rule: the only place that decides where the reset deletes itself. */
    private record ResetObject(String provider, String location, String key, List<String> registeredVersions,
                               String sourceLabel, String display, boolean recordedAbsent, boolean deletableStorage) {}

    private record State(List<Refusal> databaseRefusals, List<ResetObject> objects,
                         List<DeadEvents> deadEvents, long deadEventTotal) {}

    private State readState() {
        List<Refusal> refusals = jdbc.query("""
                SELECT sort_order, reason_code, item_count, message FROM public.fn_business_data_reset_refusals()
                ORDER BY sort_order, message
                """, (row, n) -> new Refusal(row.getString("reason_code"), row.getLong("item_count"), row.getString("message")));
        List<ResetObject> objects = jdbc.query("""
                SELECT object_provider, object_location, object_key, registered_versions, source_label, display_label,
                       recorded_absent, deletable_storage
                FROM public.fn_business_test_reset_objects() ORDER BY object_identity
                """, (row, n) -> new ResetObject(row.getString("object_provider"), row.getString("object_location"),
                row.getString("object_key"), strings(row.getArray("registered_versions")),
                row.getString("source_label"), row.getString("display_label"), row.getBoolean("recorded_absent"),
                row.getBoolean("deletable_storage")));
        Map<String, Long> byCategory = new LinkedHashMap<>();
        for (String[] category : DEAD_EVENT_CATEGORIES) byCategory.put(category[1], 0L);
        byCategory.put(OTHER_EVENTS, 0L);
        jdbc.query("SELECT event_type, count(*) AS events FROM public.business_outbox WHERE status = 2 GROUP BY event_type",
                row -> {
                    String category = deadEventCategory(row.getString("event_type"));
                    byCategory.merge(category, row.getLong("events"), Long::sum);
                });
        List<DeadEvents> dead = new ArrayList<>();
        long total = 0;
        for (var entry : byCategory.entrySet()) {
            if (entry.getValue() > 0) {
                dead.add(new DeadEvents(entry.getKey(), entry.getValue()));
                total += entry.getValue();
            }
        }
        return new State(refusals, objects, dead, total);
    }

    static String deadEventCategory(String eventType) {
        String type = eventType == null ? "" : eventType;
        for (String[] category : DEAD_EVENT_CATEGORIES) {
            if (category[0].endsWith("_") ? type.startsWith(category[0]) : type.equals(category[0])) return category[1];
        }
        return OTHER_EVENTS;
    }

    /**
     * Runs the caller identity check (directly or inside the lock function) and maps its database
     * refusals; returns the lock wait in force, for the same mapping of the reads that follow.
     */
    private String requireCaller(String sql) {
        // Read before the call: an error aborts the transaction and nothing can be read afterwards.
        String waited = jdbc.queryForObject("SELECT current_setting('lock_timeout')", String.class);
        try {
            jdbc.queryForObject(sql, String.class);
        } catch (RuntimeException error) {
            SQLException cause = sqlException(error);
            if (cause != null && "42501".equals(cause.getSQLState())) {
                String message = serverMessage(cause);
                if (message.contains("authenticated active super-admin")) {
                    throw failure(ErrorCode.FORBIDDEN, "NOT_SUPER_ADMIN", 0,
                            "只有在职的超级管理员本人可以清空业务数据。请用自己的超级管理员账号重新登录后再试。");
                }
                // Same answer on every retry: a definite server configuration failure. The reason keeps
                // only the cause (the failure receipt adds its own outcome and next step).
                if (message.contains("unexpected relation")) {
                    throw misconfigured("CALLER_NAMESPACE",
                            "数据库里出现了与清空程序内部临时表同名的数据表(reset_business_ 开头)，清空程序不能安全运行。这是数据库被人为改动或程序缺陷",
                            "，请联系开发人员处理。本次没有删除任何文件，也没有清空数据。");
                }
                throw misconfigured("CALLER_NOT_AUTHORIZED",
                        "清空程序连接数据库使用的账号无权执行清空(既不是系统运行账号，也不属于清空程序的数据库账号)。这是服务器配置问题",
                        "，请让维护人员检查数据库连接账号。本次没有删除任何文件，也没有清空数据。");
            }
            throw readFailure(error, waited);
        }
        return waited;
    }

    /** A read before anything is deleted; any database error becomes a definite, explained failure. */
    private static <T> T readMapped(Supplier<T> read, String waited) {
        try {
            return read.get();
        } catch (ApiException known) {
            throw known;
        } catch (RuntimeException error) {
            throw readFailure(error, waited);
        }
    }

    /** Database errors while checking (caller, refusals, object list, fingerprint): nothing was deleted yet. */
    private static ResetFilesFailure readFailure(RuntimeException error, String waited) {
        SQLException cause = sqlException(error);
        String state = cause == null ? null : cause.getSQLState();
        if ("55P03".equals(state)) {
            return failure(ErrorCode.CONFLICT, "LOCK_TIMEOUT", 0, String.format(
                    "有其他程序正在使用附件相关数据(可能是后台任务或另一台服务器)，等了 %s 秒仍没有结束；本次没有删除任何文件，也没有清空数据。请稍后重新点「确认清空」。",
                    seconds(waited)));
        }
        if ("57014".equals(state) || error instanceof QueryTimeoutException || error instanceof TransactionTimedOutException) {
            log.warn("business_data_reset 读取测试文件清单超时 type={} sqlstate={}", error.getClass().getSimpleName(), state);
            return failure(ErrorCode.CONFLICT, "READ_TIMEOUT", 0,
                    "读取测试文件清单时数据库超时(数据库正忙或测试文件很多)，本次没有删除任何文件，也没有清空数据。请稍后点「重新检查」再清空；如果多次出现，请联系开发人员。");
        }
        log.warn("business_data_reset 读取测试文件清单失败 type={} sqlstate={} message={}",
                error.getClass().getSimpleName(), state, cause == null ? error.getMessage() : serverMessage(cause));
        return failure(ErrorCode.INTERNAL, "DB_READ_FAILED", 0,
                "读取测试文件清单时数据库出错，本次没有删除任何文件，也没有清空数据。请稍后点「重新检查」再清空；如果再次出现，请联系开发人员。");
    }

    // ------------------------------------------------------------------ storage inspection

    private enum Outcome { ABSENT, SKIP_RECORDED, SKIP_UNSUPPORTED, DELETE, PROBLEM }

    private record Planned(ResetObject object, Outcome outcome, StorageService provider, String version,
                           String problem, String detail) {}

    /** skipped = the storage was not checked at all (a catalog refusal already makes the reset impossible). */
    private record Inspection(List<Planned> planned, boolean complete, boolean skipped, long inspected) {}

    private Inspection inspect(State state, Instant deadline) {
        List<Planned> planned = new ArrayList<>();
        boolean catalogBroken = state.databaseRefusals().stream().anyMatch(r -> CATALOG_CODES.contains(r.code()));
        if (catalogBroken) return new Inspection(planned, false, true, 0);
        Map<String, Object> providers = new HashMap<>();
        long inspected = 0;
        for (ResetObject object : state.objects()) {
            if (!Instant.now().isBefore(deadline)) return new Inspection(planned, false, false, inspected);
            planned.add(inspectOne(object, providers));
            inspected++;
        }
        return new Inspection(planned, true, false, inspected);
    }

    private Planned inspectOne(ResetObject object, Map<String, Object> providers) {
        if (!object.deletableStorage()) {
            return new Planned(object, object.recordedAbsent() ? Outcome.SKIP_RECORDED : Outcome.SKIP_UNSUPPORTED,
                    null, null, null, null);
        }
        String provider = object.provider();
        Object resolved = providers.computeIfAbsent(provider, this::resolveProvider);
        if (!(resolved instanceof StorageService service)) {
            if (object.recordedAbsent()) return new Planned(object, Outcome.SKIP_RECORDED, null, null, null, null);
            return problem(object, "local".equals(provider) ? "LOCAL_NOT_CONFIGURED" : "INTERNAL_NOT_CONFIGURED", null);
        }
        ObjectLocation location = location(object);
        try {
            StorageService.StoredObject observed = inspectWithRetry(service, location, object.key());
            if (!observed.exists()) return new Planned(object, Outcome.ABSENT, service, null, null, null);
            // The rule only lists registered versions where the stored file must match them.
            if (location == ObjectLocation.FINAL && !object.registeredVersions().isEmpty()
                    && object.registeredVersions().stream().anyMatch(v -> !v.equals(observed.versionId()))) {
                return problem(object, "VERSION_MISMATCH", null);
            }
            return new Planned(object, Outcome.DELETE, service, observed.versionId(), null, null);
        } catch (StorageLegacyLayoutException legacy) {
            return problem(object, "LOCAL_LEGACY_LAYOUT", null);
        } catch (StorageResourceUnavailableException unavailable) {
            logProblem(unavailable, object);
            return problem(object, "STORAGE_UNAVAILABLE", unavailable.getMessage());
        } catch (StorageObjectProblem bad) {
            logProblem(bad, object);
            return switch (bad.kind()) {
                case NOT_REGULAR_FILE -> problem(object, "NOT_A_FILE", "是目录或其它特殊文件");
                case UNRECOGNIZED_HEADER -> problem(object, "NOT_A_FILE", "文件头不是系统写入的格式");
                case ACCESS_DENIED -> problem(object, "READ_FAILED", "服务器没有读取权限");
                case IO_ERROR -> problem(object, "READ_FAILED", "读取时出错");
            };
        } catch (IllegalArgumentException invalidKey) {
            // The storage rejects the registered key itself: a data problem, not a storage problem.
            logProblem(invalidKey, object);
            return problem(object, "KEY_INVALID", null);
        } catch (RuntimeException error) {
            logProblem(error, object);
            return problem(object, "READ_FAILED", "读取时出错");
        }
    }

    /** One resolution per provider: the storage, or the marker that this server has none configured. */
    private Object resolveProvider(String provider) {
        try {
            return storage.require(provider);
        } catch (RuntimeException notConfigured) {
            log.warn("business_data_reset 存储未配置 provider={} type={}", provider, notConfigured.getClass().getSimpleName());
            return Boolean.FALSE;
        }
    }

    private static Planned problem(ResetObject object, String code, String detail) {
        return new Planned(object, Outcome.PROBLEM, null, null, code, detail);
    }

    private static void pause() {
        try {
            Thread.sleep(200);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Test file check was interrupted", interrupted);
        }
    }

    private static void logProblem(RuntimeException error, ResetObject object) {
        log.warn("business_data_reset 测试文件核对异常 type={} key={}", error.getClass().getSimpleName(), keyPrefix(object.key()));
    }

    // ------------------------------------------------------------------ results and messages

    private Check toCheck(State state, Inspection inspection) {
        long present = 0, absent = 0, expected = 0, expectedFound = 0;
        boolean problems = false;
        for (Planned planned : inspection.planned()) {
            switch (planned.outcome()) {
                case DELETE -> present++;
                case ABSENT, SKIP_RECORDED -> absent++;
                case PROBLEM -> problems = true;
                case SKIP_UNSUPPORTED -> { }
            }
            if (!planned.object().recordedAbsent()
                    && (planned.outcome() == Outcome.DELETE || planned.outcome() == Outcome.ABSENT)) {
                expected++;
                if (planned.outcome() == Outcome.DELETE) expectedFound++;
            }
        }
        boolean allListedMissing = inspection.complete() && !problems && expected > 0 && expectedFound == 0;
        Map<String, Set<String>> kindFiles = new LinkedHashMap<>();
        for (String label : List.of("业务附件", "上传会话", "AI识别原件", "报价模板候选", "删除任务")) {
            kindFiles.put(label, new LinkedHashSet<>());
        }
        for (ResetObject object : state.objects()) {
            kindFiles.computeIfAbsent(object.sourceLabel(), ignored -> new LinkedHashSet<>())
                    .add(object.provider() + "|" + object.key());
        }
        List<KindCount> kinds = kindFiles.entrySet().stream().filter(e -> !e.getValue().isEmpty())
                .map(e -> new KindCount(e.getKey(), e.getValue().size())).toList();
        return new Check(state.objects().size(), present, absent, inspection.inspected(), inspection.complete(),
                inspection.skipped(), allListedMissing, kinds, state.deadEvents(), refusals(state, inspection));
    }

    private List<Refusal> refusals(State state, Inspection inspection) {
        List<Refusal> refusals = new ArrayList<>(state.databaseRefusals());
        if ("oss".equals(properties.getProvider())) {
            refusals.add(new Refusal("ACTIVE_STORAGE_OSS", 0,
                    "这台服务器的附件直接上传到阿里云，上传过程不经过本系统，清空时无法确认没有正在上传的测试文件。"
                            + "测试服务器应使用内部存储：请让维护人员把附件存储改为内部存储(UTEN_STORAGE_PROVIDER=internal)后再清空。"));
        }
        Map<String, List<Planned>> byCode = new LinkedHashMap<>();
        for (String code : PROBLEM_ORDER) byCode.put(code, new ArrayList<>());
        inspection.planned().stream().filter(p -> p.outcome() == Outcome.PROBLEM)
                .forEach(p -> byCode.get(p.problem()).add(p));
        byCode.forEach((code, items) -> {
            if (!items.isEmpty()) refusals.add(new Refusal(code, items.size(), storageLine(code, items)));
        });
        return refusals;
    }

    private static String storageLine(String code, List<Planned> items) {
        int n = items.size();
        String list = sample(items);
        String details = String.join("；", items.stream().map(Planned::detail).filter(d -> d != null && !d.isBlank())
                .collect(java.util.stream.Collectors.toCollection(LinkedHashSet::new)));
        return switch (code) {
            case "STORAGE_UNAVAILABLE" -> String.format(
                    "服务器上的附件存储目录现在无法访问(存储报告：%s)，涉及 %d 个文件：%s。请让维护人员检查服务器的附件存储盘(是否挂载、目录是否被改动)后点「重新检查」。",
                    details, n, list);
            case "LOCAL_NOT_CONFIGURED" -> String.format(
                    "%d 个文件登记在本地文件目录，但这台服务器没有配置本地文件目录，无法确认它们还在不在：%s。"
                            + "请让维护人员在服务器配置里填写本地文件目录(UTEN_STORAGE_LOCAL_DIR，下面要有 staging 和 final 两个子目录)后点「重新检查」。",
                    n, list);
            case "INTERNAL_NOT_CONFIGURED" -> String.format(
                    "%d 个文件登记在内部存储，但这台服务器没有配置可用的内部存储目录，无法确认它们还在不在：%s。"
                            + "请让维护人员在服务器配置里填写内部存储目录(UTEN_INTERNAL_STORAGE_ROOT)后点「重新检查」。",
                    n, list);
            case "VERSION_MISMATCH" -> String.format(
                    "%d 个文件在存储里的内容和登记的不是同一份(文件被替换过)，系统不会删除它们：%s。需要开发人员核对哪一份是对的并处理，然后点「重新检查」。",
                    n, list);
            case "NOT_A_FILE" -> String.format(
                    "%d 个文件的存储位置上放的不是系统写入的文件(%s)：%s。请让维护人员检查服务器上的这些位置(可能被人手工放入或改动过)，移走后点「重新检查」。",
                    n, details.replace("；", "、"), list);
            case "LOCAL_LEGACY_LAYOUT" -> String.format(
                    "%d 个文件在本地文件目录里还按旧版方式直接放在根目录下，系统无法确认是哪一份：%s。需要开发人员在服务器上核对后把它们移到 final 子目录或删除，然后点「重新检查」。",
                    n, list);
            case "KEY_INVALID" -> String.format(
                    "%d 个文件的存储编号格式不对(登记的数据有问题)，系统无法定位这些文件：%s。需要开发人员核对这些登记后点「重新检查」。",
                    n, list);
            case "READ_FAILED" -> String.format(
                    "%d 个文件读取失败(%s)：%s。请让维护人员检查服务器存储和文件权限后点「重新检查」。",
                    n, details.replace("；", "、"), list);
            default -> throw new IllegalStateException("Unknown storage check code " + code);
        };
    }

    private static String sample(List<Planned> items) {
        List<String> labels = items.stream().map(p -> p.object().display()).sorted().limit(SAMPLES).toList();
        return String.join("、", labels) + (items.size() > SAMPLES ? " 等 " + items.size() + " 个" : "");
    }

    private static ResetFilesFailure failure(ErrorCode code, String reason, long count, String message) {
        return new ResetFilesFailure(code, message, List.of(new Refusal(reason, count, message)));
    }

    /** The response says cause + next step; the reason keeps the cause alone for the failure receipt. */
    private static ResetFilesFailure misconfigured(String reason, String cause, String nextStep) {
        return new ResetFilesFailure(ErrorCode.RESET_SERVER_MISCONFIGURED, cause + nextStep,
                List.of(new Refusal(reason, 0, cause)));
    }

    private static String storageWords(RuntimeException error) {
        if (error instanceof StorageResourceUnavailableException unavailable && unavailable.getMessage() != null) {
            return unavailable.getMessage();
        }
        return "读写出错";
    }

    private static ObjectLocation location(ResetObject object) {
        return "STAGING".equals(object.location()) ? ObjectLocation.STAGING : ObjectLocation.FINAL;
    }

    private static String keyPrefix(String key) {
        return key == null ? "" : key.substring(0, Math.min(8, key.length()));
    }

    private static String seconds(String setting) {
        if (setting == null) return "?";
        String value = setting.trim();
        if (value.endsWith("ms")) {
            try { return Long.toString(Math.max(1, Long.parseLong(value.substring(0, value.length() - 2)) / 1000)); }
            catch (NumberFormatException ignored) { return value; }
        }
        if (value.endsWith("s")) return value.substring(0, value.length() - 1);
        if (value.endsWith("min")) {
            try { return Long.toString(Long.parseLong(value.substring(0, value.length() - 3)) * 60); }
            catch (NumberFormatException ignored) { return value; }
        }
        return value;
    }

    private static List<String> strings(Array array) throws SQLException {
        if (array == null) return List.of();
        Object raw = array.getArray();
        if (!(raw instanceof Object[] values)) return List.of();
        return Arrays.stream(values).filter(v -> v != null).map(Object::toString).toList();
    }

    private static SQLException sqlException(Throwable error) {
        for (Throwable cause = error; cause != null; cause = cause.getCause()) {
            if (cause instanceof SQLException sql) return sql;
            if (cause.getCause() == cause) break;
        }
        return null;
    }

    private static String serverMessage(SQLException error) {
        if (error instanceof PSQLException psql && psql.getServerErrorMessage() != null
                && psql.getServerErrorMessage().getMessage() != null) {
            return psql.getServerErrorMessage().getMessage();
        }
        return error.getMessage() == null ? "" : error.getMessage();
    }
}
