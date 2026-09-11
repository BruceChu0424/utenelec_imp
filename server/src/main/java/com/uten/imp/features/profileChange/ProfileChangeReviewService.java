package com.uten.imp.features.profilechange;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.profilechange.dto.ProfileChangeDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.stream.Collectors;

/** HR 审批（事务内：校验 employee.version → 应用 → 写审计）与待办计数器。 */
@Slf4j
@Service
@RequiredArgsConstructor
public class ProfileChangeReviewService {

    private final ProfileChangeRepository repo;
    private final EmployeeRepository employeeRepo;
    private final UserAccountRepository userRepo;
    private final NoticeService noticeService;
    private final HrNoticePort hrNotice;
    private final ProfileFieldApplier applier;
    private final ProfileChangeMapper mapper;
    private final ProfileChangeSnapshotCodec snapshotCodec;
    private final ProfileChangeAccess access;
    private final TxSessionVars tx;

    /** HR 批准 / 驳回。事务内：乐观锁 → 应用字段 → 写审计。 */
    @Transactional
    public ProfileChangeDto.BatchDetail review(UUID batchId, ProfileChangeDto.ReviewAction req) {
        snapshotCodec.bindWriteCapability();
        AuthUser reviewer = access.requireHr();
        UUID reviewerId = reviewer.getId();
        tx.bindActor(reviewerId, reviewer.getLoginAccount());
        // reviewed_by 的 FK 指向 employees(id)：必须写员工档案 id，不能写 users.id，
        // 否则审批保存时触发 profile_change_requests_reviewed_by_fkey 外键违反（500）。
        // 纯管理账号（未绑定员工档案）时为 null，审计仍记录 users.id 与登录账号。
        UUID reviewerEmployeeId = reviewer.getEmployeeId();

        if (req == null || req.action() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "审批动作不能为空");
        }
        String action = req.action();
        String comment = req.comment();

        List<ProfileChangeRequest> rs = repo.findByBatchIdAndStatus(batchId, "pending");
        if (rs.isEmpty()) throw new ApiException(ErrorCode.NOT_FOUND, "无可审批批次");
        ProfileChangeRequest first = rs.get(0);
        if (reviewerEmployeeId != null && reviewerEmployeeId.equals(first.getSubmittedBy())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "不能审批自己提交的申请");
        }

        OffsetDateTime now = OffsetDateTime.now();
        switch (action) {
            case "approve" -> {
                Employee emp = employeeRepo.findById(first.getEmployeeId())
                        .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "员工档案不存在"));
                // 乐观锁：所有记录 employee_version 必须等于当前员工 version
                for (ProfileChangeRequest r : rs) {
                    if (!Integer.valueOf(emp.getVersion()).equals(r.getEmployeeVersion())) {
                        throw new ApiException(ErrorCode.CONFLICT, "档案已被他人修改，请刷新后再审");
                    }
                }
                // 应用每条变更
                for (ProfileChangeRequest r : rs) {
                    applier.applyReviewedChange(emp, r);
                    r.setStatus("applied");
                }
                emp.setVersion(emp.getVersion() + 1);
                employeeRepo.save(emp);
            }
            case "reject" -> {
                if (comment == null || comment.isBlank()) {
                    throw new ApiException(ErrorCode.VALIDATION_FAILED, "驳回意见必填");
                }
                for (ProfileChangeRequest r : rs) {
                    r.setStatus("rejected");
                }
            }
            default -> throw new ApiException(ErrorCode.VALIDATION_FAILED, "未知审批动作：" + action);
        }
        for (ProfileChangeRequest r : rs) {
            r.setReviewedBy(reviewerEmployeeId);
            r.setReviewedAt(now);
            r.setReviewComment(comment);
        }
        repo.saveAll(rs);
        // 办结撤回 HR 待审弹卡（提交时发的 PROFILE_CHANGE_SUBMITTED 行动卡）
        hrNotice.resolveProfileChangeBatch(
                batchId, "approve".equals(action) ? "APPROVED" : "REJECTED");
        notifySubmitter(rs, action, comment, reviewerEmployeeId);
        return mapper.toBatchDetail(rs);
    }

    /** 审批结果定向通知申请人（仅本人可见）。通知失败不回滚审批。 */
    private void notifySubmitter(List<ProfileChangeRequest> rs, String action,
                                 String comment, UUID reviewerEmployeeId) {
        try {
            UUID submitterEmployeeId = rs.get(0).getSubmittedBy();
            UUID submitterUserId = userRepo.findByEmployeeId(submitterEmployeeId)
                    .map(UserAccount::getId)
                    .orElse(null);
            if (submitterUserId == null) return;    // 无登录账号（离职账号已删）跳过

            String fields = rs.stream()
                    .map(r -> fieldLabelForNotice(r.getFieldCode(), r.getFieldLabel()))
                    .distinct().limit(5).collect(Collectors.joining("、"));
            String publisher = reviewerEmployeeId == null ? "系统"
                    : employeeRepo.findById(reviewerEmployeeId).map(Employee::getFullName).orElse("系统");
            if ("approve".equals(action)) {
                noticeService.publishForUser(submitterUserId,
                        "个人信息修改已批准",
                        "您提交的 " + rs.size() + " 项个人信息修改(" + fields + ")已批准并生效。",
                        "approval", publisher);
            } else {
                noticeService.publishForUser(submitterUserId,
                        "个人信息修改被驳回",
                        "您提交的 " + rs.size() + " 项个人信息修改(" + fields + ")已被驳回。"
                                + (comment == null || comment.isBlank() ? "" : "驳回意见：" + comment),
                        "approval", publisher, "/profile/edit",
                        "PROFILE_CHANGE_REJECTED", "important");
            }
        } catch (Exception e) {
            log.warn("审批结果通知发送失败(不影响审批本身): {}", e.getMessage());
        }
    }

    /** 仅需审核字段（进审批通知）的 code→中文映射；直改字段不进表/通知，无需列。 */
    private static final Map<String, String> FIELD_LABEL_ZH = Map.of(
            "fullName", "姓名",
            "hujiAddress", "户籍地址",
            "phone", "手机号"
    );

    /**
     * 通知正文里展示的字段名。优先按 fieldCode 映射中文——历史上 field_label 可能被
     * 存成 i18n key（profileChangeFieldFullName）或裸机器码（emergencyContact.1.phone），
     * 直接拼进通知会把系统字段结构暴露给用户；这里统一回落到中文，机器码绝不外泄。
     */
    private String fieldLabelForNotice(String code, String storedLabel) {
        String zh = FIELD_LABEL_ZH.get(code);
        if (zh != null) return zh;
        if (code != null && code.startsWith("emergencyContact.")) {
            String tail = code.substring("emergencyContact.".length());
            int dot = tail.indexOf('.');
            String sub = dot > 0 ? tail.substring(dot + 1) : tail;
            return switch (sub) {
                case "name" -> "紧急联系人姓名";
                case "phone" -> "紧急联系人电话";
                case "relationship" -> "紧急联系人关系";
                default -> "紧急联系人";
            };
        }
        // 存储的 label 若仍是机器码（英文 camelCase / 含 . _），不暴露给用户
        if (storedLabel != null && !storedLabel.isBlank()
                && !storedLabel.trim().matches("^[A-Za-z][A-Za-z0-9._]*$")) {
            return storedLabel.trim();
        }
        return "个人信息";
    }

    /** 某员工的待审数（员工详情 Hero 后区块用）。 */
    @Transactional(readOnly = true)
    public long pendingCountForEmployee(UUID employeeId) {
        if (!access.hasReviewPerm()) return 0;
        return repo.countByEmployeeIdAndStatus(employeeId, "pending");
    }

    /** 当前 HR 全局待办数（导航徽章）。 */
    @Transactional(readOnly = true)
    public long pendingCount() {
        if (!access.hasReviewPerm()) return 0;
        return repo.countByStatus("pending");
    }
}
