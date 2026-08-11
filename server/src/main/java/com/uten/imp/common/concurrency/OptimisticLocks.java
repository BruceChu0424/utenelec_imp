package com.uten.imp.common.concurrency;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

/**
 * 乐观锁工具：统一"记录已被他人修改"的版本校验（防丢失更新）。
 *
 * <p>用法：实体加 JPA {@code @Version}（DB 列 {@code version}，每次写自增，flush 时自动比对），
 * 编辑 DTO 携带读到的 {@code version} 回传，服务端在 update 入口调用
 * {@link #requireUpToDate(long, Long)} 做显式比对。
 *
 * <ul>
 *   <li>显式比对：捕获"前端基于旧版本编辑"的常见场景，给出可操作提示；</li>
 *   <li>JPA {@code @Version} flush 自动比对：兜底"load 与 commit 之间的窄窗口竞态"。</li>
 * </ul>
 * 两者都收敛为 409 CONFLICT（显式抛 {@link ApiException}；JPA 自动抛由 GlobalExceptionHandler 翻译）。
 * {@code expectedVersion} 为 null 表示客户端未参与（如旧客户端），放行——不破坏前向兼容。
 */
public final class OptimisticLocks {

    private OptimisticLocks() {}

    /** 期望版本非空且与当前不符 → 409；期望为 null 放行（兼容不回传版本的客户端）。 */
    public static void requireUpToDate(long currentVersion, Long expectedVersion) {
        if (expectedVersion != null && expectedVersion.longValue() != currentVersion) {
            throw new ApiException(ErrorCode.CONFLICT, "该记录已被他人修改，请刷新后重试");
        }
    }
}
