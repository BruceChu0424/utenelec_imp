package com.uten.imp.features.suggestion;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.suggestion.dto.SuggestionDto;
import com.uten.imp.features.suggestion.dto.SuggestionReplyDto;
import com.uten.imp.features.suggestion.dto.SuggestionReplyRequest;
import com.uten.imp.features.suggestion.dto.SuggestionSubmitRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * 建议箱读写。广场全员可见；匿名建议在服务端脱敏（仅本人与持 suggestion:reply 者可见真名）。
 *
 * <p>状态机：submitted → reviewing → resolved/rejected；回复时可顺带推进（newStatus）。
 */
@Service
@RequiredArgsConstructor
public class SuggestionService {

    private static final Set<String> CATEGORIES = Set.of(
            "product", "process", "welfare", "environment", "equipment", "other");
    private static final Set<String> STATUSES = Set.of(
            "submitted", "reviewing", "resolved", "rejected");

    private final SuggestionRepository suggestionRepo;
    private final SuggestionReplyRepository replyRepo;
    private final SuggestionLikeRepository likeRepo;
    private final EmployeeRepository employeeRepo;
    private final SecurityContextCurrentUser currentUser;

    /** 广场列表（全员，时间倒序）或我的建议。category 可空。 */
    @Transactional(readOnly = true)
    public List<SuggestionDto> list(String scope, String category) {
        AuthUser u = requireStaff();
        List<Suggestion> rows;
        if ("mine".equals(scope)) {
            rows = suggestionRepo.findBySubmitterIdOrderBySubmittedAtDesc(u.getId());
        } else if (category != null && !category.isBlank()) {
            rows = suggestionRepo.findByCategoryOrderBySubmittedAtDesc(category);
        } else {
            rows = suggestionRepo.findAllByOrderBySubmittedAtDesc();
        }
        Set<UUID> likedIds = likedSuggestionIds(u.getId());
        List<SuggestionDto> out = new ArrayList<>(rows.size());
        for (Suggestion s : rows) {
            // 广场列表不展开回复（详情才带），避免 N+1
            out.add(toDto(s, u, likedIds.contains(s.getId()), List.of()));
        }
        return out;
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
        return toDto(s, u, liked, replies);
    }

    /** 提交建议（suggestion:submit）。提交人取当前员工姓名快照。 */
    @Transactional
    public SuggestionDto submit(SuggestionSubmitRequest req) {
        AuthUser u = requireStaff();
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
        // 提交回执对本人不脱敏（本人当然知道自己是谁）
        return toDto(s, u, false, List.of());
    }

    /** 点赞切换（有则取消、无则点赞），返回最新建议。 */
    @Transactional
    public SuggestionDto toggleLike(UUID id) {
        AuthUser u = requireStaff();
        Suggestion s = suggestionRepo.findById(id)
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
        return toDto(s, u, nowLiked, List.of());
    }

    /** 官方回复（suggestion:reply）。可顺带推进状态（newStatus 可空）。 */
    @Transactional
    public SuggestionDto reply(UUID id, SuggestionReplyRequest req) {
        AuthUser u = requireStaff();
        Suggestion s = suggestionRepo.findById(id)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "建议不存在"));
        if (req.content() == null || req.content().isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "回复内容不能为空");
        }
        if (req.newStatus() != null && !req.newStatus().isBlank()) {
            if (!STATUSES.contains(req.newStatus())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "非法状态: " + req.newStatus());
            }
            s.setStatus(req.newStatus());
            suggestionRepo.save(s);
        }

        SuggestionReply r = new SuggestionReply();
        r.setSuggestionId(id);
        r.setReplierId(u.getId());
        r.setReplierName(employeeName(u));
        r.setReplierRole(departmentName(u));
        r.setContent(req.content().trim());
        r.setRepliedAt(Instant.now());
        replyRepo.save(r);
        return getById(id);
    }

    // ---------- 内部 ----------

    private SuggestionDto toDto(Suggestion s, AuthUser viewer, boolean likedByMe,
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
                likeRepo.countByIdSuggestionId(s.getId()),
                likedByMe,
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

    private Set<UUID> likedSuggestionIds(UUID userId) {
        Set<UUID> ids = new HashSet<>();
        for (SuggestionLike like : likeRepo.findByIdUserId(userId)) {
            ids.add(like.getId().getSuggestionId());
        }
        return ids;
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
