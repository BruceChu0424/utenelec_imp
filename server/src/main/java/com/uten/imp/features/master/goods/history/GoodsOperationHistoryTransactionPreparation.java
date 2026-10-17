package com.uten.imp.features.master.goods.history;

import com.uten.imp.application.port.TransactionWritePreparationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Set;

/** Acquires the personal command lock before any master row can be locked. */
@Component
@RequiredArgsConstructor
public class GoodsOperationHistoryTransactionPreparation implements TransactionWritePreparationPort {
    private static final Set<String> WRITE_METHODS = Set.of("POST", "PUT", "PATCH", "DELETE");
    private final EntityManager em;

    @Override
    public void prepare(String requestPath, String requestMethod) {
        if (requestMethod == null || !WRITE_METHODS.contains(requestMethod)
                || requestPath == null
                || !(under(requestPath, "/api/master/goods")
                || under(requestPath, "/api/master/material-categories"))) {
            return;
        }
        // The database owns the exact route allowlist and reads the actor from
        // the provenance already bound on this transaction's own connection.
        try {
            em.createNativeQuery("SELECT fn_begin_goods_history_request()").getSingleResult();
        } catch (RuntimeException failure) {
            for (Throwable cause = failure; cause != null; cause = cause.getCause()) {
                if (cause instanceof java.sql.SQLException sql && "55P03".equals(sql.getSQLState())) {
                    var busy = new ApiException(ErrorCode.CONFLICT,
                            "当前账号的货品操作仍在处理中，本次没有修改资料；请稍后刷新重试");
                    busy.initCause(failure);
                    throw busy;
                }
            }
            throw failure;
        }
    }

    private static boolean under(String path, String root) {
        return path.equals(root) || path.startsWith(root + "/");
    }
}
