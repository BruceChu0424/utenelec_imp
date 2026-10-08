package com.uten.imp.common.web;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.ConstraintViolationException;
import lombok.extern.slf4j.Slf4j;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.core.AuthenticationException;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.bind.MissingServletRequestParameterException;
import org.springframework.web.HttpMediaTypeNotSupportedException;
import org.springframework.web.multipart.MultipartException;
import org.springframework.web.multipart.MaxUploadSizeExceededException;
import org.springframework.web.multipart.support.MissingServletRequestPartException;
import org.springframework.web.context.request.async.AsyncRequestNotUsableException;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;
import org.springframework.web.servlet.NoHandlerFoundException;
import org.springframework.web.servlet.resource.NoResourceFoundException;
import org.springframework.transaction.TransactionTimedOutException;

import java.util.List;
import java.sql.SQLException;
import org.postgresql.util.PSQLException;
import org.postgresql.util.ServerErrorMessage;

/** 全局异常处理：统一转 ApiError，不向前端泄露堆栈/SQL/状态码细节。 */
@Slf4j
@RestControllerAdvice
public class GlobalExceptionHandler {

    /** PostgreSQL 等锁超时(lock_timeout)。 */
    static final String LOCK_NOT_AVAILABLE = "55P03";
    /** PostgreSQL 语句被取消(statement_timeout / 事务剩余时间用尽)。 */
    static final String QUERY_CANCELED = "57014";
    /** PostgreSQL 检测到死锁, 本事务被选为牺牲者。 */
    static final String DEADLOCK_DETECTED = "40P01";
    static final String LOCK_BUSY_MESSAGE = "有人正在处理相关单据，本次操作未生效，请稍后再试";
    static final String TIMED_OUT_MESSAGE = "本次操作处理时间过长已自动取消，没有生效，请稍后再试";
    static final String DEADLOCK_MESSAGE = "与他人同时处理相关单据发生冲突，本次操作未生效，请稍后再试";

    @ExceptionHandler(ApiException.class)
    public ResponseEntity<ApiError> handleApi(ApiException ex) {
        var response = ResponseEntity.status(ex.getCode().getHttpStatus());
        // 并发冲突可重试 (ADR-107) 与密码哈希闸门满 (ADR-110 AUTH_BUSY): 都告诉客户端 1 秒后可重试, 不必当成服务故障。
        if (ex.retryable() || ex.getCode() == ErrorCode.AUTH_BUSY) {
            response.header(HttpHeaders.RETRY_AFTER, "1");
        }
        return response.body(ApiError.of(ex.getCode(), ex.getMessage(), ex.getFieldErrors()));
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ApiError> handleValidation(MethodArgumentNotValidException ex) {
        List<ApiError.FieldError> fields = ex.getBindingResult().getFieldErrors().stream()
                .map(f -> new ApiError.FieldError(f.getField(), f.getDefaultMessage()))
                .toList();
        return ResponseEntity.status(422)
                .body(ApiError.of(ErrorCode.VALIDATION_FAILED, "填写的内容有误，请检查后重试", fields));
    }

    @ExceptionHandler(ConstraintViolationException.class)
    public ResponseEntity<ApiError> handleConstraint(ConstraintViolationException ex) {
        List<ApiError.FieldError> fields = ex.getConstraintViolations().stream()
                .map(v -> new ApiError.FieldError(v.getPropertyPath().toString(), v.getMessage()))
                .toList();
        return ResponseEntity.status(422)
                .body(ApiError.of(ErrorCode.VALIDATION_FAILED, "填写的内容有误，请检查后重试", fields));
    }

    @ExceptionHandler(MissingServletRequestParameterException.class)
    public ResponseEntity<ApiError> handleMissingParam(MissingServletRequestParameterException ex) {
        return ResponseEntity.status(400)
                .body(ApiError.of(ErrorCode.MALFORMED_REQUEST, "缺少查询条件: " + ex.getParameterName()));
    }

    @ExceptionHandler(MethodArgumentTypeMismatchException.class)
    public ResponseEntity<ApiError> handleTypeMismatch(MethodArgumentTypeMismatchException ex) {
        return ResponseEntity.status(400)
                .body(ApiError.of(ErrorCode.MALFORMED_REQUEST, "查询条件 " + ex.getName() + " 的格式不对"));
    }

    // 未匹配路由（无 controller）或静态资源不存在：Spring 6.1+ 抛 NoResourceFoundException；
    // 启用 throw-exception-if-no-handler-found 时抛 NoHandlerFoundException。两者都应收敛为 404，
    // 否则会被下面的 Exception 兜底吞成 500（API 后端无 SPA 转发，404 是正确语义）。
    @ExceptionHandler({NoResourceFoundException.class, NoHandlerFoundException.class})
    public ResponseEntity<ApiError> handleRouteNotFound(Exception ex) {
        return ResponseEntity.status(404).body(ApiError.of(ErrorCode.NOT_FOUND, null));
    }

    // 路径存在但方法不对 (如已删除的写接口只剩 GET)：405, 不被兜底吞成 500。
    @ExceptionHandler(org.springframework.web.HttpRequestMethodNotSupportedException.class)
    public ResponseEntity<ApiError> handleMethodNotAllowed(
            org.springframework.web.HttpRequestMethodNotSupportedException ex) {
        return ResponseEntity.status(405).body(ApiError.of(ErrorCode.METHOD_NOT_ALLOWED, null));
    }

    @ExceptionHandler(JsonBodyTooLargeException.class)
    public ResponseEntity<ApiError> handleJsonBodyTooLarge(JsonBodyTooLargeException ex) {
        return ResponseEntity.status(ErrorCode.PAYLOAD_TOO_LARGE.getHttpStatus())
                .body(ApiError.of(ErrorCode.PAYLOAD_TOO_LARGE, null));
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<ApiError> handleUnreadableBody(HttpMessageNotReadableException ex) {
        Throwable cause = ex;
        while (cause != null) {
            if (cause instanceof JsonBodyTooLargeException tooLarge) {
                return handleJsonBodyTooLarge(tooLarge);
            }
            cause = cause.getCause();
        }
        return ResponseEntity.status(ErrorCode.MALFORMED_REQUEST.getHttpStatus())
                .body(ApiError.of(ErrorCode.MALFORMED_REQUEST, null));
    }

    @ExceptionHandler(HttpMediaTypeNotSupportedException.class)
    public ResponseEntity<ApiError> handleUnsupportedMediaType(HttpMediaTypeNotSupportedException ex) {
        return ResponseEntity.status(ErrorCode.UNSUPPORTED_MEDIA_TYPE.getHttpStatus())
                .body(ApiError.of(ErrorCode.UNSUPPORTED_MEDIA_TYPE, null));
    }

    @ExceptionHandler(MaxUploadSizeExceededException.class)
    public ResponseEntity<ApiError> handleMultipartTooLarge(MaxUploadSizeExceededException ex) {
        return ResponseEntity.status(ErrorCode.PAYLOAD_TOO_LARGE.getHttpStatus())
                .body(ApiError.of(ErrorCode.PAYLOAD_TOO_LARGE, null));
    }

    @ExceptionHandler({MissingServletRequestPartException.class, MultipartException.class})
    public ResponseEntity<ApiError> handleMalformedMultipart(Exception ex) {
        return ResponseEntity.status(ErrorCode.MALFORMED_REQUEST.getHttpStatus())
                .body(ApiError.of(ErrorCode.MALFORMED_REQUEST, "上传内容缺失或格式不正确"));
    }

    @ExceptionHandler(AuthenticationException.class)
    public ResponseEntity<ApiError> handleAuth(AuthenticationException ex) {
        return ResponseEntity.status(401).body(ApiError.of(ErrorCode.UNAUTHORIZED, null));
    }

    @ExceptionHandler(AccessDeniedException.class)
    public ResponseEntity<ApiError> handleAccessDenied(AccessDeniedException ex) {
        return ResponseEntity.status(403).body(ApiError.of(ErrorCode.FORBIDDEN, null));
    }

    /**
     * 数据库完整性/数据类错误(Spring 把 SQLSTATE 22xxx/23xxx 都翻译成 DataIntegrityViolationException)。
     * 口径见 {@link #integrityOutcome}: 业务守卫的中文原因原样给人看(422), 规则不满足给中性话(422),
     * 只有真正的并发占用/重复/引用变化才回 409; 任何情况下都不回显 SQL/DETAIL/WHERE/CONTEXT。
     */
    @ExceptionHandler(DataIntegrityViolationException.class)
    public ResponseEntity<ApiError> handleDataIntegrity(DataIntegrityViolationException ex) {
        return integrityResponse(integrityOutcome(ex.getMostSpecificCause()));
    }

    // JdbcTemplate 的完整性异常由 Spring 翻译为 DataIntegrityViolationException（上一条已兜住）；
    // 但 Service 层经 EntityManager 执行的原生 SQL（如采购到货超收触发器
    // fn_guard_procurement_received_with_arrival_allowance）抛出的是 Hibernate 的
    // ConstraintViolationException，@Service 不在持久化异常翻译范围内，会原样上抛。
    // 不单独处理则落入 handleOther → 裸 500。此处按同一完整性口径兜底。
    @ExceptionHandler(org.hibernate.exception.ConstraintViolationException.class)
    public ResponseEntity<ApiError> handleHibernateConstraint(
            org.hibernate.exception.ConstraintViolationException ex) {
        return integrityResponse(integrityOutcome(ex));
    }

    // 乐观锁冲突（JPA @Version 在 flush 时发现版本不符，或显式版本校验失败经持久化层抛出）。
    // 不单独处理会落入 handleOther → 裸 500。统一收敛为 409 + 可操作提示。
    // 服务层显式版本校验直接抛 ApiException(CONFLICT)（已被 handleApi 兜住），此处兜底 JPA 自动机制。
    @ExceptionHandler({
            org.springframework.dao.OptimisticLockingFailureException.class,
            jakarta.persistence.OptimisticLockException.class})
    public ResponseEntity<ApiError> handleOptimisticLock(Exception ex) {
        return ResponseEntity.status(409)
                .body(ApiError.of(ErrorCode.CONFLICT, "该记录已被他人修改，请刷新后重试"));
    }

    /**
     * 服务端截止时间(ADR-107): 等锁超时、语句/事务超时被取消、死锁牺牲。事务已整体回滚、什么都没生效,
     * 统一回可重跑的 409(带 Retry-After), 前端提示稍后再试, 不再落成裸 500 或无限排队。
     */
    @ExceptionHandler({
            org.springframework.dao.PessimisticLockingFailureException.class,
            org.springframework.dao.QueryTimeoutException.class,
            jakarta.persistence.PessimisticLockException.class,
            jakarta.persistence.LockTimeoutException.class,
            jakarta.persistence.QueryTimeoutException.class,
            TransactionTimedOutException.class})
    public ResponseEntity<ApiError> handleDatabaseDeadline(Exception ex) {
        String message = deadlineMessage(ex);
        return retryableConflict(ex, message != null ? message : LOCK_BUSY_MESSAGE);
    }

    private ResponseEntity<ApiError> retryableConflict(Exception ex, String message) {
        log.warn("Database deadline reached, request rolled back: {} sqlState={}",
                ex.getClass().getSimpleName(), sqlState(ex));
        return ResponseEntity.status(409).header(HttpHeaders.RETRY_AFTER, "1")
                .body(ApiError.of(ErrorCode.CONFLICT, message));
    }

    /** 沿异常链找 PostgreSQL 截止时间类 SQLState; 不是这几类返回 null。 */
    static String deadlineMessage(Throwable root) {
        int depth = 0;
        for (Throwable cause = root; cause != null && depth < 16; cause = cause.getCause(), depth++) {
            if (cause instanceof TransactionTimedOutException) return TIMED_OUT_MESSAGE;
            if (cause instanceof SQLException sql && sql.getSQLState() != null) {
                switch (sql.getSQLState()) {
                    case LOCK_NOT_AVAILABLE: return LOCK_BUSY_MESSAGE;
                    case QUERY_CANCELED: return TIMED_OUT_MESSAGE;
                    case DEADLOCK_DETECTED: return DEADLOCK_MESSAGE;
                    default: break;
                }
            }
        }
        return null;
    }

    private static String sqlState(Throwable root) {
        int depth = 0;
        for (Throwable cause = root; cause != null && depth < 16; cause = cause.getCause(), depth++) {
            if (cause instanceof SQLException sql && sql.getSQLState() != null) return sql.getSQLState();
        }
        return "none";
    }

    /** 中性文案: CHECK/NOT NULL/未登记的英文守卫 —— 提交内容不满足数据规则, 不是并发冲突。 */
    static final String RULE_VIOLATION_MESSAGE = "提交的内容不符合数据规则，请检查后重试";
    /** 22xxx 数据类错误(数值溢出、文字超长、格式不对)。 */
    static final String DATA_RANGE_MESSAGE = "提交的数值或文字超出可保存的范围，请检查后重试";
    /** 23505/23P01: 唯一或排他冲突 —— 多半是并发占用或重复提交。 */
    static final String DUPLICATE_MESSAGE = "这条数据已被其他操作占用或已重复提交，请刷新后查看结果";
    /** 23503: 外键 —— 引用的资料刚被删除, 或要删的资料仍被引用。 */
    static final String REFERENCE_MESSAGE = "相关资料已被删除或仍被其它数据引用，请刷新后重试";
    /** 行版本守卫没有中文原因时的说法(并发改写, 409)。 */
    static final String VERSION_CONFLICT_MESSAGE = "该记录已被他人修改，请刷新后重试";
    static final String VERSION_GUARD_SUFFIX = "_version_guard";
    /** 链上找不到 SQLSTATE 的兜底(旁路包装)。 */
    static final String INTEGRITY_FALLBACK_MESSAGE = "数据已被其他操作更新，或数量超出可处理范围，请刷新后重试";
    /** PL/pgSQL RAISE 的服务端例程名; 真正的 CHECK 违反是 ExecConstraints, 与 lc_messages 语言无关。 */
    static final String PLPGSQL_RAISE_ROUTINE = "exec_stmt_raise";
    private static final java.util.regex.Pattern HAN = java.util.regex.Pattern.compile("\\p{IsHan}");
    private static final int GUARD_MESSAGE_LIMIT = 300;

    /** 完整性错误对外的错误码 + 文案(状态码随错误码)。 */
    record IntegrityOutcome(ErrorCode code, String message) {}

    private static ResponseEntity<ApiError> integrityResponse(IntegrityOutcome outcome) {
        return ResponseEntity.status(outcome.code().getHttpStatus())
                .body(ApiError.of(outcome.code(), outcome.message()));
    }

    /**
     * 数据库完整性错误的唯一映射点(ADR-151 §4):
     * <ol>
     *   <li>已登记的约束/守卫(白名单)保持原来的专门文案与 409;</li>
     *   <li>23514 且约束名以 _version_guard 结尾(行版本守卫): 别人刚改过, 409, 有中文原因时原样回显;</li>
     *   <li>23514 且是我们自己的守卫函数 RAISE(例程 exec_stmt_raise)、文案是中文: 原样回显第一行(422),
     *       只取主消息, 不带 DETAIL/HINT/WHERE/CONTEXT;</li>
     *   <li>其余 23514(真正的 CHECK 约束、英文守卫): 中性文案 422, 约束名只进服务端日志;</li>
     *   <li>23502 / 22xxx: 写请求回 422(中性文案 / 数值文字超范围); 读请求(GET/HEAD)不可能是用户填错,
     *       一律 500。两种都按服务端缺陷记 error 日志并带完整堆栈, 不把程序问题伪装成用户输入问题;</li>
     *   <li>23505/23P01 重复占用: 409; 我们自己的守卫函数 RAISE 的中文原因原样回显(同 23514 的回显规则);</li>
     *   <li>23503 引用变化: 409。</li>
     * </ol>
     */
    IntegrityOutcome integrityOutcome(Throwable root) {
        String registered = registeredIntegrityMessage(root);
        if (registered != null) return new IntegrityOutcome(ErrorCode.CONFLICT, registered);
        SQLException sql = integritySqlException(root);
        String state = sql == null ? null : sql.getSQLState();
        ServerErrorMessage server = sql instanceof PSQLException postgres ? postgres.getServerErrorMessage() : null;
        if ("23514".equals(state)) {
            String guard = businessGuardMessage(server);
            // 版本守卫(约束名 *_version_guard)是并发改写, 不是规则不满足: 409, 让页面重读后再试。
            if (versionGuard(server)) {
                return new IntegrityOutcome(ErrorCode.CONFLICT, guard != null ? guard : VERSION_CONFLICT_MESSAGE);
            }
            if (guard != null) return new IntegrityOutcome(ErrorCode.VALIDATION_FAILED, guard);
            logIntegrity("rule violation", sql, server, root);
            return new IntegrityOutcome(ErrorCode.VALIDATION_FAILED, RULE_VIOLATION_MESSAGE);
        }
        if ("23502".equals(state) || (state != null && state.startsWith("22"))) {
            // NOT NULL / 数据类错误多半是服务端拼参数或漏列(DTO 已做长度与必填校验): 记完整堆栈。
            log.error("Database {} (sqlState={} constraint={} table={})",
                    "23502".equals(state) ? "not null violation" : "data exception", state,
                    server == null ? null : server.getConstraint(), server == null ? null : server.getTable(), root);
            if (readOnlyRequest()) return new IntegrityOutcome(ErrorCode.INTERNAL, null);
            return new IntegrityOutcome(ErrorCode.VALIDATION_FAILED,
                    "23502".equals(state) ? RULE_VIOLATION_MESSAGE : DATA_RANGE_MESSAGE);
        }
        if ("23505".equals(state) || "23P01".equals(state)) {
            String guard = businessGuardMessage(server);
            if (guard != null) return new IntegrityOutcome(ErrorCode.CONFLICT, guard);
            logIntegrity("duplicate", sql, server, root);
            return new IntegrityOutcome(ErrorCode.CONFLICT, DUPLICATE_MESSAGE);
        }
        if ("23503".equals(state)) {
            logIntegrity("reference changed", sql, server, root);
            return new IntegrityOutcome(ErrorCode.CONFLICT, REFERENCE_MESSAGE);
        }
        logIntegrity("integrity conflict", sql, server, root);
        return new IntegrityOutcome(ErrorCode.CONFLICT, INTEGRITY_FALLBACK_MESSAGE);
    }

    /** 当前请求是读请求(GET/HEAD): 读请求没有用户提交的内容, 数据类错误只可能是服务端缺陷。 */
    static boolean readOnlyRequest() {
        var attributes = org.springframework.web.context.request.RequestContextHolder.getRequestAttributes();
        if (!(attributes instanceof org.springframework.web.context.request.ServletRequestAttributes servlet)) {
            return false;
        }
        String method = servlet.getRequest().getMethod();
        return "GET".equalsIgnoreCase(method) || "HEAD".equalsIgnoreCase(method);
    }

    /** 约束名以 _version_guard 结尾的守卫(V409/V740/V802 等的行版本守卫): 别人刚改过, 属于并发冲突。 */
    static boolean versionGuard(ServerErrorMessage server) {
        String constraint = server == null ? null : server.getConstraint();
        return constraint != null && constraint.endsWith(VERSION_GUARD_SUFFIX);
    }

    /** 业务守卫(RAISE ... USING ERRCODE='23514')写给人看的中文原因; 不是这类返回 null。 */
    static String businessGuardMessage(ServerErrorMessage server) {
        if (server == null || !PLPGSQL_RAISE_ROUTINE.equals(server.getRoutine())) return null;
        String message = server.getMessage();
        if (message == null) return null;
        String line = message.strip().split("\\r?\\n", 2)[0].strip();
        if (line.isEmpty() || !HAN.matcher(line).find()) return null;
        return line.length() > GUARD_MESSAGE_LIMIT ? line.substring(0, GUARD_MESSAGE_LIMIT) : line;
    }

    /** 链上第一个带 22xxx/23xxx SQLSTATE 的 SQLException。 */
    private static SQLException integritySqlException(Throwable root) {
        int depth = 0;
        for (Throwable cause = root; cause != null && depth < 16; cause = cause.getCause(), depth++) {
            if (cause instanceof SQLException sql && sql.getSQLState() != null
                    && (sql.getSQLState().startsWith("23") || sql.getSQLState().startsWith("22"))) {
                return withServerDetail(sql);
            }
        }
        return null;
    }

    /**
     * JPA flush 走 JDBC 批量执行时, 驱动抛的是 BatchUpdateException(只有 SQLState, 没有服务端细节),
     * 带守卫原文、约束名、例程名的 PSQLException 挂在 getNextException 上。取它, 否则守卫的中文原因
     * 会被当成无名约束落成中性文案(2026-10-04 仓库资料改仓库用途时实测)。
     */
    private static SQLException withServerDetail(SQLException sql) {
        int depth = 0;
        for (SQLException next = sql; next != null && depth < 8; next = next.getNextException(), depth++) {
            if (next instanceof PSQLException postgres && postgres.getServerErrorMessage() != null) return next;
        }
        return sql;
    }

    /** 只进服务端日志: 约束名/表/例程/首行, 便于不翻数据库日志就知道撞的是哪条规则。 */
    private static void logIntegrity(String kind, SQLException sql, ServerErrorMessage server, Throwable root) {
        String message = sql != null ? sql.getMessage() : root == null ? null : root.getMessage();
        String firstLine = message == null ? "" : message.strip().split("\\r?\\n", 2)[0];
        log.warn("Database {}: sqlState={} constraint={} table={} routine={} {} {}", kind,
                sql == null ? "none" : sql.getSQLState(),
                server == null ? null : server.getConstraint(),
                server == null ? null : server.getTable(),
                server == null ? null : server.getRoutine(),
                root == null ? "unknown" : root.getClass().getSimpleName(),
                firstLine.length() > 300 ? firstLine.substring(0, 300) : firstLine);
    }

    /** 已登记(白名单)的约束与守卫: 专门的大白话; 数据库细节仍不外露。没有登记返回 null。 */
    private String registeredIntegrityMessage(Throwable root) {
        int depth = 0;
        for (Throwable cause = root; cause != null && depth < 16; cause = cause.getCause(), depth++) {
            if (!(cause instanceof SQLException batch) || !"23514".equals(batch.getSQLState())) continue;
            SQLException sql = withServerDetail(batch);
            if (sql instanceof PSQLException postgres && postgres.getServerErrorMessage()!=null) {
                var databaseError=postgres.getServerErrorMessage();
                String constraint=databaseError.getConstraint();
                if ("final_report_pending_drafts".equals(constraint)) {
                    // Only this reviewed guard contains user-facing document numbers.
                    // Never return the SQL, DETAIL, WHERE or stack portion of the exception.
                    String message=databaseError.getMessage();
                    if(message!=null && message.startsWith("该工单还有未审核报工单")) return message;
                    return "该工单还有未审核报工草稿，请先审核或删除这些草稿，再提前完结";
                }
                if ("actual_output_effective_rate_limit".equals(constraint)) {
                    return "本次实际产量超过已批准的允许超产范围，请先办理追加生产计划再报工";
                }
                if ("final_report_surplus_authorization_identity".equals(constraint)) {
                    return "本次报工数量与提前完结时批准的实际产出不一致，请核对原报工记录";
                }
                // V736 车间直送资格断言(ADR-127)：库里的原因文案是统一维护的大白话，原样给用户；
                // 只认这个约束名与固定开头，不回显 SQL/DETAIL/WHERE。
                if ("workshop_direct_target_guard".equals(constraint)) {
                    String message=databaseError.getMessage();
                    if(message!=null && message.startsWith("无法转到下一道工序：")) return message;
                    return "无法转到下一道工序：上层工单当前不能接收，请刷新后重新选择";
                }
                String subcontractDraw = subcontractDrawGuardMessage(constraint, databaseError.getMessage());
                if (subcontractDraw != null) return subcontractDraw;
            }
            String detail = sql.getMessage();
            String subcontractDraw = subcontractDrawGuardMessage(null, detail);
            if (subcontractDraw != null) return subcontractDraw;
            if (detail != null && (detail.contains("Custody has already been issued by its destination task")
                    || detail.contains("Returned source has already been consumed by its destination"))) {
                return "这批余料已被后续工单领用，请先处理对应后续领料，再撤回收仓";
            }
            if (detail != null && detail.contains("Original material receipt has later actual stock consumption")) {
                return "本次收仓之后已有依赖其成本的出库，请先处理对应后续出库，再撤回收仓";
            }
            // ADR-111 主档完整性兜底(V683/V684)：服务端正常路径会先给出列明细的原因，这里只在
            // 并发或旁路写入撞上数据库闸时出现，给一句能照着做的话，不回显库内细节。
            String masterGuard = masterIntegrityMessage(detail);
            if (masterGuard != null) return masterGuard;
        }
        String message = root == null ? null : root.getMessage();
        if (message != null
                && message.contains("master code is reserved for another identity")) {
            return "该编号已被当前或历史主档使用，不能重复分配；请更换编号";
        }
        if (message != null
                && message.contains("received_qty exceeds finance-approved arrival capacity")) {
            return "该订货明细的可收数量已用尽(可能已被其他收货单审核入库)，无法重复入库";
        }
        return null;
    }

    /**
     * ADR-143(V798) 委外按工序领料 / 分批回厂的数据库闸(23514)的大白话。服务端正常路径会先给出逐行原因
     * (例如「仓库只能少发不能多发」「请先在委外任务中心领料」), 这里只在并发或旁路写入撞上数据库闸时出现;
     * 先认约束名, 驱动没带约束名(纯 SQLException)时按固定英文句首或约束名子串认。不回显 SQL/DETAIL/WHERE。
     * 不是这几条就返回 null, 交给后面的通用文案。
     */
    static String subcontractDrawGuardMessage(String constraint, String message) {
        String text = message == null ? "" : message;
        if (matches(constraint, text, "subcontract_target_outbound_first_guard")
                || text.contains("subcontract receipt material basis nets more than")
                || text.contains("subcontract receipt has no frozen draw plan lines")
                || text.contains("subcontract receipt consumes more of a material than the supplier holds")) {
            if (text.contains("has no frozen draw plan lines")) {
                return "该委外订货明细没有领料计划(直属物料)，可回厂数量为 0；请先维护委外件 BOM，并在委外任务中心领料后再登记回厂";
            }
            if (text.contains("consumes more of a material than the supplier holds")) {
                return "委外商手里的直属物料不够核销这次回厂(已被回厂核销的发料也不能再红冲或退料)；"
                        + "请刷新后核对委外领料、退料与回厂记录";
            }
            return "回厂数量超过委外商用已发直属物料能做成的套数，超出部分要先在到货异常里经财务批准(委外商自带料)；"
                    + "请刷新预计到货后按可回厂数量登记，或先在委外任务中心领料";
        }
        if (matches(constraint, text, "subcontract_target_outbound_consumption_guard")
                || text.contains("subcontract receipt material consumption")) {
            return "委外回厂核销的直属物料数量与回厂数量对不上，本次操作没有生效；请刷新后重试";
        }
        if (matches(constraint, text, "subcontract_receipt_material_basis_guard")
                || matches(constraint, text, "subcontract_receipt_item_material_basis_chk")
                || text.contains("approved subcontract receipt line lacks its frozen material basis")) {
            return "委外回厂明细缺少物料核销依据，本次操作没有生效；请刷新后重试";
        }
        if (matches(constraint, text, "subcontract_material_issue_item_requested_qty_chk")) {
            return "仓库出仓数量不能超过委外人员提交的领料数量，只能改少；请改小后再提交";
        }
        if (matches(constraint, text, "subcontract_draw_issue_requested_guard")
                || text.contains("submitted draw quantity and its plan line are immutable")
                || text.contains("draw-plan issue lines are created only by a subcontract draw submission")
                || text.contains("only draw-plan issue lines carry a submitted draw quantity")) {
            return "委外领料单的物料行和提交数量只能由委外领料生成，仓库只能改少、填 0 不发或整张退回委外；请刷新拣货页后重试";
        }
        if (matches(constraint, text, "subcontract_draw_issue_identity_guard")
                || text.contains("subcontract draw is only accepted on an open plan line")
                || text.contains("subcontract issue line must carry the exact frozen draw-plan material")) {
            if (text.contains("open plan line")) {
                return "该委外任务已结束领料或订货已结清，不能再领料发料；请刷新后核对";
            }
            return "委外领料行必须是该任务领料计划里的物料(物料与颜色不能改)；请刷新拣货页后重试";
        }
        if (matches(constraint, text, "subcontract_draw_plan_basis_guard")
                || text.contains("subcontract draw plan line must freeze one drawable direct BOM edge")) {
            return "委外件的 BOM 刚有改动，领料计划与当前 BOM 的直属物料对不上；请刷新后重新审批";
        }
        if (matches(constraint, text, "subcontract_material_plan_items_check")) {
            return "委外直属物料累计发出不能超过领料计划量；请刷新后核对本次出仓数量";
        }
        if (matches(constraint, text, "subcontract_material_plan_items_issued_qty_check")) {
            return "该直属物料已发外的数量不够这次红冲或退料；请刷新后核对委外发料与退料记录";
        }
        if (text.contains("approved subcontract draw issue lacks exact reservation coverage")
                || text.contains("subcontract outbound allocation provenance is inconsistent")
                || text.contains("subcontract outbound reservation lacks exact issue allocation")) {
            return "委外领料单的库存占用与出仓明细对不上(可能刚被撤回、退回或改少)，本次操作没有生效；请刷新拣货页后重试";
        }
        return null;
    }

    private static boolean matches(String constraint, String message, String name) {
        return name.equals(constraint) || message.contains(name);
    }

    /** V683/V684 主档触发器(23514)的大白话；不是这几条就返回 null 交给通用文案。 */
    private static String masterIntegrityMessage(String detail) {
        if (detail == null) return null;
        if (detail.contains("goods is still a component of an active BOM")) {
            return "这个货品还是其它货品组装清单(BOM)里的组件，不能删除；请先在用到它的货品的 BOM 里移除它";
        }
        if (detail.contains("color is still used by an active goods row")) {
            return "这个颜色还有货品或组装清单(BOM)在用，不能删除；请先修改这些货品或 BOM";
        }
        if (detail.contains("unit is still used by an active goods row")) {
            return "这个单位还有货品在用，不能删除；请先修改这些货品";
        }
        if (detail.contains("goods category has been deleted")
                || detail.contains("active master requires an active category")) {
            return "所选分类刚被删除，请刷新后重新选择分类";
        }
        if (detail.contains("category parent has been deleted")) {
            return "上级分类刚被删除，请刷新后重新选择上级分类";
        }
        return null;
    }

    // 客户端在响应写回前主动断开（前端热重启/刷新/取消请求/关闭页面）：
    // ServletOutputStream 已不可用，任何写回（包括本 advice 生成的错误体）都会再抛。
    // 业务侧无影响——GET 读请求无状态，写请求事务早已提交，只是响应送不出去。
    // 不当错误处理：只记 DEBUG 一行，避免 ERROR + 全栈噪音淹没真实故障。
    // （实测 Spring 6.2 以 AsyncRequestNotUsableException 包裹 ClientAbortException
    // 进入本 advice；此前落入 handleOther 被记成「未处理异常」。）
    @ExceptionHandler(AsyncRequestNotUsableException.class)
    public void handleClientAbortedResponse(
            AsyncRequestNotUsableException ex, HttpServletRequest request) {
        log.debug("客户端中断响应（刷新/热重启/取消请求）: {} {}",
                request.getMethod(), request.getRequestURI());
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ApiError> handleOther(Exception ex) {
        // Hibernate/JPA 在 @Service 里抛出的原生异常类型各不相同, 按根因 SQLState 统一识别截止时间类。
        String deadline = deadlineMessage(ex);
        if (deadline != null) return retryableConflict(ex, deadline);
        // Deferred constraints can surface only at COMMIT, wrapped by JPA's
        // transaction exception. Keep the same response as the direct adapters.
        String state = sqlState(ex);
        if (state.startsWith("23") || state.startsWith("22")) {
            return integrityResponse(integrityOutcome(ex));
        }
        log.error("未处理异常", ex);
        return ResponseEntity.status(500).body(ApiError.of(ErrorCode.INTERNAL, null));
    }
}
