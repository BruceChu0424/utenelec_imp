package com.uten.imp.common.web;

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
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;
import org.springframework.web.servlet.NoHandlerFoundException;
import org.springframework.web.servlet.resource.NoResourceFoundException;

import java.util.List;

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

    /** 到货收货数量超过财务核定可收上限时给出可操作提示；其余完整性冲突给通用提示。 */
    private String integrityMessage(Throwable root) {
        String message = root == null ? null : root.getMessage();
        if (message != null
                && message.contains("master code is reserved for another identity")) {
            return "该编号已被当前或历史主档使用，不能重复分配；请更换编号";
        }
        if (message != null
                && message.contains("received_qty exceeds finance-approved arrival capacity")) {
            return "该订货明细的可收数量已用尽（可能已被其他收货单审核入库），无法重复入库";
        }
        log.warn("Database integrity conflict: {}",
                root == null ? "unknown" : root.getClass().getSimpleName());
        return "数据已被其他操作更新，或数量超出可处理范围，请刷新后重试";
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ApiError> handleOther(Exception ex) {
        log.error("未处理异常", ex);
        return ResponseEntity.status(500).body(ApiError.of(ErrorCode.INTERNAL, null));
    }
}
