package com.uten.imp.common.web;

import com.uten.imp.application.port.WarehouseTaskScopePort;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;
import java.util.Objects;

/**
 * 只读请求(GET/HEAD)整请求一个仓库数据范围快照(ADR-149 §2.1)。
 *
 * <p>读请求不改组织、部门、负责人与账号, 整个请求共用一次 {@code fn_user_warehouse_access} 解析是安全的:
 * 列表逐行判定、详情加附件、列表加计数都只解析一次。写请求不经这里, 每次实时解析(同一请求里先改组织、
 * 后判定必须拿到新结果); 批量办理循环在服务里显式开窗口。
 *
 * <p>注册在 Spring Security 过滤链之后(主体已解析, 鉴权失败的请求不进来)。窗口由
 * {@link WarehouseTaskScopePort#withScopeCache} 在 finally 里关闭: 处理抛错、异步/流式响应(处理线程一返回
 * 就关, 异步线程本来看不到这个 ThreadLocal)都不会把窗口带进线程池里的下一个请求; 异步与错误分派不再进来
 * ({@link OncePerRequestFilter} 默认)。
 */
public final class WarehouseScopeReadSnapshotFilter extends OncePerRequestFilter {
    private final WarehouseTaskScopePort scopes;

    public WarehouseScopeReadSnapshotFilter(WarehouseTaskScopePort scopes) {
        this.scopes = Objects.requireNonNull(scopes);
    }

    @Override protected boolean shouldNotFilter(HttpServletRequest request) {
        return !"GET".equals(request.getMethod()) && !"HEAD".equals(request.getMethod());
    }

    @Override protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        try {
            scopes.withScopeCache(() -> {
                try {
                    chain.doFilter(request, response);
                } catch (IOException | ServletException failure) {
                    throw new ChainFailure(failure);
                }
                return null;
            });
        } catch (ChainFailure wrapped) {
            // 窗口已关; 过滤链的受检异常原样抛回容器。
            if (wrapped.getCause() instanceof IOException io) throw io;
            throw (ServletException) wrapped.getCause();
        }
    }

    /** 让过滤链的受检异常穿过 {@code Supplier}。 */
    private static final class ChainFailure extends RuntimeException {
        ChainFailure(Exception cause) {
            super(cause.getMessage(), cause, false, false);
        }
    }
}
