package com.uten.imp.features.visitor;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.visitor.dto.VisitorScanDto.EmployeeDirectoryItem;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/**
 * 访客搜索接待人(security-08 / permissions-13)：
 * <ul>
 *   <li>只按姓名前缀匹配，关键字至少 {@value #MIN_KEYWORD_LENGTH} 个字，最多返回 {@value #MAX_RESULTS} 人；
 *       不接受部门参数，也不接受工号匹配。</li>
 *   <li>只返回可对外接待的员工(持接待访客权限，见 {@link VisitorHostEligibility})。</li>
 *   <li>结果只有 id 和姓名，不带部门——外部账号拼不出组织结构。</li>
 *   <li>按访客账号和来源地址限流，每次查询(含被限流的)都写一条审计。</li>
 * </ul>
 */
@Service
@RequiredArgsConstructor
public class VisitorDirectoryService {

    /** 一次最多返回的接待人候选数。 */
    static final int MAX_RESULTS = 5;
    /** 关键字最少字数(按字符计，中文一个字算一个)。 */
    static final int MIN_KEYWORD_LENGTH = 2;
    /** 关键字最多字数(姓名不会更长，防超长输入进审计)。 */
    static final int MAX_KEYWORD_LENGTH = 20;

    static final String AUDIT_ACTION = "visitor_host_search";
    static final String AUDIT_ACTION_LIMITED = "visitor_host_search_limited";
    private static final String AUDIT_TARGET = "visitor_directory";

    private final VisitorHostEligibility hostEligibility;
    private final VisitorDirectoryRateLimiter rateLimiter;
    private final AuditService audit;
    private final SecurityContextCurrentUser currentUser;

    @Transactional(readOnly = true)
    public List<EmployeeDirectoryItem> searchHosts(String keyword, String clientIp) {
        AuthUser visitor = currentUser.get()
                .filter(AuthUser::isVisitor)
                .orElseThrow(() -> new ApiException(ErrorCode.FORBIDDEN, "仅访客可搜索接待人"));
        String trimmed = keyword == null ? "" : keyword.trim();
        int length = trimmed.codePointCount(0, trimmed.length());
        if (length < MIN_KEYWORD_LENGTH || length > MAX_KEYWORD_LENGTH) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请输入接待人姓名，至少 2 个字");
        }
        try {
            rateLimiter.check(visitor.getId(), clientIp);
        } catch (ApiException limited) {
            audit.logExplicit(visitor.getId(), visitor.getVisitorNo(), AUDIT_ACTION_LIMITED,
                    AUDIT_TARGET, null, "搜索接待人过于频繁，已拦下：关键字「" + trimmed + "」");
            throw limited;
        }
        List<EmployeeDirectoryItem> hosts = hostEligibility.searchByNamePrefix(trimmed, MAX_RESULTS).stream()
                .map(host -> new EmployeeDirectoryItem(host.employeeId(), host.name()))
                .toList();
        audit.logExplicit(visitor.getId(), visitor.getVisitorNo(), AUDIT_ACTION,
                AUDIT_TARGET, null, "搜索接待人：关键字「" + trimmed + "」，找到 " + hosts.size() + " 人");
        return hosts;
    }
}
