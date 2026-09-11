package com.uten.imp.features.suggestion;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.suggestion.dto.SuggestionDto;
import com.uten.imp.features.suggestion.dto.SuggestionReplyDto;
import com.uten.imp.features.suggestion.dto.SuggestionReplyRequest;
import com.uten.imp.features.suggestion.dto.SuggestionSubmitRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/**
 * 建议箱读写。广场全员可见；匿名建议在服务端脱敏（仅本人与持 suggestion:reply 者可见真名）。
 *
 * <p>状态机：submitted → reviewing → resolved/rejected；回复时可顺带推进（newStatus）。
 *
 * <p>通知（2026-09-10，{@link HrNoticePort}）：提交 → 持 suggestion:reply 者收
 * SUGGESTION_SUBMITTED 行动卡（提交人除外，匿名不带姓名）；回复推进到终态 → 办结该卡并
 * 回执提交人本人。与业务同事务。
 */
@Service
@RequiredArgsConstructor
public class SuggestionService {

    private static final Set<String> CATEGORIES = Set.of(
            "product", "process", "welfare", "environment", "equipment", "other");
    private static final Set<String> STATUSES = Set.of(
            "submitted", "reviewing", "resolved", "rejected");
    private static final Set<String> TERMINAL_STATUSES = Set.of("resolved", "rejected");

    private final SuggestionRepository suggestionRepo;
    private final SuggestionReplyRepository replyRepo;
    private final SuggestionLikeRepository likeRepo;
    private final EmployeeRepository employeeRepo;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;
    private final HrNoticePort hrNotice;

    /**
     * 广场/我的建议服务端分页。
     *
     * <p>排序必须带 UUID 兜底，否则相同提交时间的记录跨页时可能重复或遗漏。
     * 点赞态、点赞数和回复数只按当前页批量查询，不随历史数据量增长。
     *
     * <p>2026-09-10：列表页「状态」表头筛选下推 status（空 = 不筛），与 scope/category
     * 正交；服务端筛选才能命中未加载页的记录（前端页内裁剪做不到）。
     */
    @Transactional(readOnly = true)
    public PageResponse<SuggestionDto> list(
            String scope,
            String category,
            String status,
            int page,
            int size) {
        AuthUser u = requireStaff();
        String normalizedScope = normalizeScope(scope);
        String normalizedCategory = normalizeCategory(category);
        String normalizedStatus = normalizeStatus(status);
        validatePage(page, size);

        Pageable pageable = Pageables.of(page, size, Sort.by(
                Sort.Order.desc("submittedAt"),
                Sort.Order.desc("id")));
        boolean mine = "mine".equals(normalizedScope);
        Page<Suggestion> result;
        if (mine && normalizedCategory != null && normalizedStatus != null) {
            result = suggestionRepo.findBySubmitterIdAndCategoryAndStatus(
                    u.getId(), normalizedCategory, normalizedStatus, pageable);
        } else if (mine && normalizedCategory != null) {
            result = suggestionRepo.findBySubmitterIdAndCategory(
                    u.getId(), normalizedCategory, pageable);
        } else if (mine && normalizedStatus != null) {
            result = suggestionRepo.findBySubmitterIdAndStatus(
                    u.getId(), normalizedStatus, pageable);
        } else if (mine) {
            result = suggestionRepo.findBySubmitterId(u.getId(), pageable);
        } else if (normalizedCategory != null && normalizedStatus != null) {
            result = suggestionRepo.findByCategoryAndStatus(
                    normalizedCategory, normalizedStatus, pageable);
        } else if (normalizedCategory != null) {
            result = suggestionRepo.findByCategory(normalizedCategory, pageable);
        } else if (normalizedStatus != null) {
            result = suggestionRepo.findByStatus(normalizedStatus, pageable);
        } else {
            result = suggestionRepo.findAll(pageable);
        }

        List<Suggestion> rows = result.getContent();
        List<UUID> ids = rows.stream().map(Suggestion::getId).toList();
        Set<UUID> likedIds = ids.isEmpty()
                ? Set.of()
                : new HashSet<>(likeRepo.findLikedSuggestionIds(u.getId(), ids));
        Map<UUID, Long> likeCounts = likeCounts(ids);
        Map<UUID, Long> replyCounts = replyCounts(ids);
        List<SuggestionDto> out = new ArrayList<>(rows.size());
        for (Suggestion s : rows) {
            out.add(toDto(
                    s,
                    u,
                    likedIds.contains(s.getId()),
                    likeCounts.getOrDefault(s.getId(), 0L),
                    replyCounts.getOrDefault(s.getId(), 0L),
                    List.of()));
        }
        return new PageResponse<>(
                out,
                result.getNumber() + 1,
                result.getSize(),
                result.getTotalElements(),
                result.getTotalPages());
    }

    /** 详情（含回复，按回复时间升序）。 */
    @Transactional(readOnly = true)
    public SuggestionDto getById(UUID id) {
        AuthUser u = requireStaff();
        Suggestion s = suggestionRepo.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "建议不存在"));
        List<SuggestionReplyDto> replies = new ArrayList<>();
        for (SuggestionReply r : replyRepo.findBySuggestionIdOrderByRepliedAtAsc(id)) {
            replies.add(new SuggestionReplyDto(
                    r.getId().toString(), r.getReplierName(), r.getReplierRole(),
                    r.getContent(), r.getRepliedAt()));
        }
        boolean liked = likeRepo.existsById(new SuggestionLikeId(id, u.getId()));
        return toDto(
                s,
                u,
                liked,
                likeRepo.countByIdSuggestionId(id),
                replies.size(),
                replies);
    }

    /** 提交建议（suggestion:submit）。提交人取当前员工姓名快照。 */
    @Transactional
    public SuggestionDto submit(SuggestionSubmitRequest req) {
        AuthUser u = requireStaff();
        tx.bind();
        if (req.title() == null || req.title().isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "标题不能为空");
        }
        if (req.content() == null || req.content().trim().length() < 10) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "内容请至少填写 10 字");
        }
        String category = req.category() == null ? "other" : req.category();
        if (!CATEGORIES.contains(category)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法建议类别: " + category);
        }

        Suggestion s = new Suggestion();
        s.setSubmitterId(u.getId());
        s.setSubmitterName(employeeName(u));
        s.setCategory(category);
        s.setTitle(req.title().trim());
        s.setContent(req.content().trim());
        s.setAnonymous(Boolean.TRUE.equals(req.isAnonymous()));
        s.setSubmittedAt(Instant.now());
        suggestionRepo.save(s);
        // 提交 → 回复人行动卡（提交人除外；匿名不带姓名）。save 后 id 已生成（UUID 主键）。
        hrNotice.notifySuggestionSubmitted(
                s.getId(), u.getId(), s.getSubmitterName(), s.getTitle(), s.isAnonymous());
        // 提交回执对本人不脱敏（本人当然知道自己是谁）
        return toDto(s, u, false, 0, 0, List.of());
    }

    /**
     * 点赞切换（有则取消、无则点赞）。
     *
     * <p>先锁建议主行，再检查关联行。所有实例都遵循相同数据库行锁，因此同一建议上的
     * 并发 toggle 不会发生 exists-then-insert TOCTOU 或唯一键异常。
     */
    @Transactional
    public SuggestionDto toggleLike(UUID id) {
        AuthUser u = requireStaff();
        tx.bind();
        Suggestion s = suggestionRepo.findByIdForUpdate(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "建议不存在"));
        SuggestionLikeId likeId = new SuggestionLikeId(id, u.getId());
        boolean nowLiked;
        if (likeRepo.existsById(likeId)) {
            likeRepo.deleteById(likeId);
            nowLiked = false;
        } else {
            SuggestionLike like = new SuggestionLike();
            like.setId(likeId);
            likeRepo.save(like);
            nowLiked = true;
        }
        likeRepo.flush();
        return toDto(
                s,
                u,
                nowLiked,
                likeRepo.countByIdSuggestionId(id),
                replyRepo.countBySuggestionId(id),
                List.of());
    }

    /**
     * 官方回复（suggestion:reply）。
     *
     * <p>不传 newStatus 表示仅补充同状态回复；显式传当前状态也视为同状态回复。
     * 真正的状态变更只允许 submitted → reviewing → resolved/rejected，终态不可倒退
     * 或互相切换。主行悲观锁保证并发回复按数据库提交顺序逐一校验。
     */
    @Transactional
    public SuggestionDto reply(UUID id, SuggestionReplyRequest req) {
        AuthUser u = requireStaff();
        tx.bind();
        Suggestion s = suggestionRepo.findByIdForUpdate(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "建议不存在"));
        if (req.content() == null || req.content().isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "回复内容不能为空");
        }
        boolean changed = advanceStatus(s, req.newStatus());
        if (changed) {
            suggestionRepo.save(s);
        }

        SuggestionReply r = new SuggestionReply();
        r.setSuggestionId(id);
        r.setReplierId(u.getId());
        r.setReplierName(employeeName(u));
        r.setReplierRole(departmentName(u));
        r.setContent(req.content().trim());
        r.setRepliedAt(Instant.now());
        replyRepo.saveAndFlush(r);
        // 推进到终态 → 办结回复人行动卡 + 回执提交人（仅本人；匿名亦不外露姓名）。
        // 终态后仅补回复不再重复回执（changed=false）。
        if (changed && TERMINAL_STATUSES.contains(s.getStatus())) {
            hrNotice.notifySuggestionClosed(
                    s.getId(), s.getSubmitterId(), s.getTitle(), s.getStatus());
        }
        return detailDto(s, u);
    }

    // ---------- 内部 ----------

    private SuggestionDto toDto(
            Suggestion s,
            AuthUser viewer,
            boolean likedByMe,
            long likes,
            long replyCount,
            List<SuggestionReplyDto> replies) {
        boolean mine = s.getSubmitterId().equals(viewer.getId());
        boolean canSeeRealName = !s.isAnonymous() || mine || canReply(viewer);
        String name = canSeeRealName ? s.getSubmitterName() : maskName(s.getSubmitterName());
        return new SuggestionDto(
                s.getId().toString(),
                // 匿名时对无权者连 submitterId 也不暴露（防遍历反查）
                canSeeRealName ? s.getSubmitterId().toString() : "",
                name,
                s.getCategory(),
                s.getTitle(),
                s.getContent(),
                s.getStatus(),
                s.getSubmittedAt(),
                s.isAnonymous(),
                likes,
                likedByMe,
                replyCount,
                replies);
    }

    /** 匿名脱敏：张优腾 → 张**（单名 → 匿名用户）。与前端 displayName 规则一致。 */
    private static String maskName(String name) {
        if (name == null || name.length() <= 1) return "匿名用户";
        return name.charAt(0) + "**";
    }

    private boolean canReply(AuthUser u) {
        return u.isSuperAdmin() || u.getPermissions().contains("suggestion:reply");
    }

    private SuggestionDto detailDto(Suggestion suggestion, AuthUser viewer) {
        List<SuggestionReplyDto> replies = new ArrayList<>();
        for (SuggestionReply reply
                : replyRepo.findBySuggestionIdOrderByRepliedAtAsc(suggestion.getId())) {
            replies.add(new SuggestionReplyDto(
                    reply.getId().toString(),
                    reply.getReplierName(),
                    reply.getReplierRole(),
                    reply.getContent(),
                    reply.getRepliedAt()));
        }
        boolean liked = likeRepo.existsById(
                new SuggestionLikeId(suggestion.getId(), viewer.getId()));
        return toDto(
                suggestion,
                viewer,
                liked,
                likeRepo.countByIdSuggestionId(suggestion.getId()),
                replies.size(),
                replies);
    }

    private Map<UUID, Long> likeCounts(List<UUID> suggestionIds) {
        Map<UUID, Long> counts = new HashMap<>();
        if (suggestionIds.isEmpty()) return counts;
        for (SuggestionLikeRepository.SuggestionCount row
                : likeRepo.countBySuggestionIds(suggestionIds)) {
            counts.put(row.getSuggestionId(), row.getTotal());
        }
        return counts;
    }

    private Map<UUID, Long> replyCounts(List<UUID> suggestionIds) {
        Map<UUID, Long> counts = new HashMap<>();
        if (suggestionIds.isEmpty()) return counts;
        for (SuggestionReplyRepository.SuggestionCount row
                : replyRepo.countBySuggestionIds(suggestionIds)) {
            counts.put(row.getSuggestionId(), row.getTotal());
        }
        return counts;
    }

    private static String normalizeScope(String scope) {
        if (scope == null || scope.isBlank() || "square".equals(scope)) {
            return "square";
        }
        if ("mine".equals(scope)) return "mine";
        throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法建议范围: " + scope);
    }

    private static String normalizeCategory(String category) {
        if (category == null || category.isBlank()) return null;
        if (!CATEGORIES.contains(category)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法建议类别: " + category);
        }
        return category;
    }

    /** 列表「状态」筛选：空 = 不筛；非法值直接拒绝（与类别同口径）。 */
    private static String normalizeStatus(String status) {
        if (status == null || status.isBlank()) return null;
        if (!STATUSES.contains(status)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法建议状态: " + status);
        }
        return status;
    }

    private static void validatePage(int page, int size) {
        if (page < 1) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "页码必须大于等于 1");
        }
        if (size < 1 || size > 100) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "每页条数必须在 1 到 100 之间");
        }
    }

    private static boolean advanceStatus(Suggestion suggestion, String requested) {
        if (requested == null || requested.isBlank()) return false;
        if (!STATUSES.contains(requested)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法状态: " + requested);
        }
        String current = suggestion.getStatus();
        if (requested.equals(current)) return false;
        boolean allowed = "submitted".equals(current) && "reviewing".equals(requested)
                || "reviewing".equals(current)
                && ("resolved".equals(requested) || "rejected".equals(requested));
        if (!allowed) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "建议状态不允许从 " + current + " 变更为 " + requested);
        }
        suggestion.setStatus(requested);
        return true;
    }

    private String employeeName(AuthUser u) {
        if (u.getEmployeeId() != null) {
            return employeeRepo.findById(u.getEmployeeId())
                    .map(Employee::getFullName)
                    .orElse(u.getLoginAccount());
        }
        return u.getLoginAccount();
    }

    private String departmentName(AuthUser u) {
        if (u.getEmployeeId() != null) {
            return employeeRepo.findById(u.getEmployeeId())
                    .map(e -> e.getDepartment() != null ? e.getDepartment().getName() : "")
                    .orElse("");
        }
        return "";
    }

    private AuthUser requireStaff() {
        AuthUser u = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (u.isVisitor()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅员工可访问");
        }
        return u;
    }
}
