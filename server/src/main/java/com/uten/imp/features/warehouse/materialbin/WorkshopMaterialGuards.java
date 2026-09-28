package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.postgresql.util.PSQLException;

import java.util.function.Supplier;

/**
 * 把 V740 数据库守卫 (23514) 的拒绝原因原样交给员工。
 *
 * <p>V740 的守卫文案都是写给员工看的中文 (不含表名、代号), 服务端能先查的已经先查并给出更具体的话;
 * 并发或漏查撞上数据库守卫时, 这里把那句中文带出来, 而不是落成通用的"数据已被其他操作更新"。
 * 只认 V740 自己的约束名前缀, 其它约束照旧交给全局异常处理。提交时才触发的延迟断言不经过这里。
 */
final class WorkshopMaterialGuards {

    private WorkshopMaterialGuards() {}

    static <T> T guarded(Supplier<T> action) {
        try {
            return action.get();
        } catch (RuntimeException error) {
            throw translate(error);
        }
    }

    static void guarded(Runnable action) {
        guarded(() -> {
            action.run();
            return null;
        });
    }

    static RuntimeException translate(RuntimeException error) {
        if (error instanceof ApiException) return error;
        int depth = 0;
        for (Throwable cause = error; cause != null && depth < 16; cause = cause.getCause(), depth++) {
            if (cause instanceof PSQLException postgres && "23514".equals(postgres.getSQLState())
                    && postgres.getServerErrorMessage() != null) {
                String constraint = postgres.getServerErrorMessage().getConstraint();
                String message = postgres.getServerErrorMessage().getMessage();
                if (constraint != null && message != null && ownConstraint(constraint)) {
                    return new ApiException(ErrorCode.CONFLICT, message);
                }
            }
        }
        return error;
    }

    private static boolean ownConstraint(String constraint) {
        return constraint.startsWith("workshop_material")
                || constraint.startsWith("workshop_machine")
                || constraint.startsWith("periodic_")
                || constraint.startsWith("goods_periodic")
                || constraint.startsWith("goods_issue_method");
    }
}
