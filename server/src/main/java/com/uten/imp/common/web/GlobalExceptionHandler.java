package com.uten.imp.common.web;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.ConstraintViolationException;
import lombok.extern.slf4j.Slf4j;
import org.springframework.dao.DataIntegrityViolationException;
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

import java.util.List;
import java.sql.SQLException;

/** 全局异常处理：统一转 ApiError，不向前端泄露堆栈/SQL/状态码细节。 */
@Slf4j
@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(ApiException.class)
    public ResponseEntity<ApiError> handleApi(ApiException ex) {
        return ResponseEntity.status(ex.getCode().getHttpStatus())
                .body(ApiError.of(ex.getCode(), ex.getMessage(), ex.getFieldErrors()));
    }

    @ExceptionHandler(MethodArgumentNotValidException.class)
    public ResponseEntity<ApiError> handleValidation(MethodArgumentNotValidException ex) {
        List<ApiError.FieldError> fields = ex.getBindingResult().getFieldErrors().stream()
                .map(f -> new ApiError.FieldError(f.getField(), f.getDefaultMessage()))
                .toList();
        return ResponseEntity.status(422)
                .body(ApiError.of(ErrorCode.VALIDATION_FAILED, "参数校验失败", fields));
    }

    @ExceptionHandler(ConstraintViolationException.class)
    public ResponseEntity<ApiError> handleConstraint(ConstraintViolationException ex) {
        List<ApiError.FieldError> fields = ex.getConstraintViolations().stream()
                .map(v -> new ApiError.FieldError(v.getPropertyPath().toString(), v.getMessage()))
                .toList();
        return ResponseEntity.status(422)
                .body(ApiError.of(ErrorCode.VALIDATION_FAILED, "参数校验失败", fields));
    }

    @ExceptionHandler(MissingServletRequestParameterException.class)
    public ResponseEntity<ApiError> handleMissingParam(MissingServletRequestParameterException ex) {
        return ResponseEntity.status(400)
                .body(ApiError.of(ErrorCode.MALFORMED_REQUEST, "缺少必需的查询参数: " + ex.getParameterName()));
    }

    @ExceptionHandler(MethodArgumentTypeMismatchException.class)
    public ResponseEntity<ApiError> handleTypeMismatch(MethodArgumentTypeMismatchException ex) {
        return ResponseEntity.status(400)
                .body(ApiError.of(ErrorCode.MALFORMED_REQUEST, "参数格式错误: " + ex.getName()));
    }

    // 未匹配路由（无 controller）或静态资源不存在：Spring 6.1+ 抛 NoResourceFoundException；
    // 启用 throw-exception-if-no-handler-found 时抛 NoHandlerFoundException。两者都应收敛为 404，
    // 否则会被下面的 Exception 兜底吞成 500（API 后端无 SPA 转发，404 是正确语义）。
    @ExceptionHandler({NoResourceFoundException.class, NoHandlerFoundException.class})
    public ResponseEntity<ApiError> handleRouteNotFound(Exception ex) {
        return ResponseEntity.status(404).body(ApiError.of(ErrorCode.NOT_FOUND, null));
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

    @ExceptionHandler(DataIntegrityViolationException.class)
    public ResponseEntity<ApiError> handleDataIntegrity(DataIntegrityViolationException ex) {
        return ResponseEntity.status(409)
                .body(ApiError.of(ErrorCode.CONFLICT, integrityMessage(ex.getMostSpecificCause())));
    }

    // JdbcTemplate 的完整性异常由 Spring 翻译为 DataIntegrityViolationException（上一条已兜住）；
    // 但 Service 层经 EntityManager 执行的原生 SQL（如采购到货超收触发器
    // fn_guard_procurement_received_with_arrival_allowance）抛出的是 Hibernate 的
    // ConstraintViolationException，@Service 不在持久化异常翻译范围内，会原样上抛。
    // 不单独处理则落入 handleOther → 裸 500。此处补 409 兜底。
    @ExceptionHandler(org.hibernate.exception.ConstraintViolationException.class)
    public ResponseEntity<ApiError> handleHibernateConstraint(
            org.hibernate.exception.ConstraintViolationException ex) {
        return ResponseEntity.status(409)
                .body(ApiError.of(ErrorCode.CONFLICT, integrityMessage(ex)));
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

    @ExceptionHandler({
            org.springframework.dao.PessimisticLockingFailureException.class,
            jakarta.persistence.PessimisticLockException.class,
            jakarta.persistence.LockTimeoutException.class})
    public ResponseEntity<ApiError> handlePessimisticLock(Exception ex) {
        return ResponseEntity.status(409)
                .body(ApiError.of(
                        ErrorCode.CONFLICT, "并发操作占用，请刷新后重试"));
    }

    /** Known business conflicts have actionable messages; database details remain private. */
    private String integrityMessage(Throwable root) {
        int depth = 0;
        for (Throwable cause = root; cause != null && depth < 16; cause = cause.getCause(), depth++) {
            if (!(cause instanceof SQLException sql) || !"23514".equals(sql.getSQLState())) continue;
            String detail = sql.getMessage();
            if (detail != null && (detail.contains("Custody has already been issued by its destination task")
                    || detail.contains("Returned source has already been consumed by its destination"))) {
                return "这批余料已被后续工单领用，请先处理对应后续领料，再撤回收仓";
            }
            if (detail != null && detail.contains("Original material receipt has later actual stock consumption")) {
                return "本次收仓之后已有依赖其成本的出库，请先处理对应后续出库，再撤回收仓";
            }
            // V458/V634 委外前置自制谱系守卫(DEFERRED, 在 COMMIT 时抛): 订货行数量超过前置自制
            // 台账 required_qty 或通知批次 notify_qty。2026-09-21 实测这类 409 只显示通用文案,
            // 财务/委外部无法判断该改哪张单。
            if (detail != null && detail.contains("subcontract prepared-outbound lineage is inconsistent")) {
                return "委外订货明细数量超过前置自制台账或通知批次可下单量(或订货行来源与前置自制批次对不上)，"
                        + "请核对委外前置自制台账与通知批次后重新提交";
            }
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
        // 只记类名时排查要翻数据库日志才知道是哪条约束(2026-09-21 委外批量批准实测):
        // 这里把根因首行一并记下(仅服务端日志, 客户端仍只收通用文案)。
        String firstLine = message == null ? "" : message.strip().split("\\r?\\n", 2)[0];
        log.warn("Database integrity conflict: {} {}",
                root == null ? "unknown" : root.getClass().getSimpleName(),
                firstLine.length() > 300 ? firstLine.substring(0, 300) : firstLine);
        return "数据已被其他操作更新，或数量超出可处理范围，请刷新后重试";
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
        log.error("未处理异常", ex);
        return ResponseEntity.status(500).body(ApiError.of(ErrorCode.INTERNAL, null));
    }
}
