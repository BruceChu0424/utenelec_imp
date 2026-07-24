package com.uten.imp.features.profilechange;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.profilechange.dto.ProfileChangeDto;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** HR 审批（事务内：校验 employee.version → 应用 → 写审计）与待办计数器。 */
@Service
@RequiredArgsConstructor
public class ProfileChangeReviewService {

    private final ProfileChangeRepository repo;
    private final EmployeeRepository employeeRepo;
    private final ProfileFieldApplier applier;
    private final ProfileChangeMapper mapper;
    private final ProfileChangeAccess access;
    private final TxSessionVars tx;

    /** HR 批准 / 驳回。事务内：乐观锁 → 应用字段 → 写审计。 */
    @Transactional
    public ProfileChangeDto.BatchDetail review(UUID batchId, ProfileChangeDto.ReviewAction req) {
        AuthUser reviewer = access.requireHr();
        UUID reviewerId = reviewer.getId();
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
            r.setReviewedBy(reviewerId);
            r.setReviewedAt(now);
            r.setReviewComment(comment);
        }
        tx.bindActor(reviewerId);
        repo.saveAll(rs);
        return mapper.toBatchDetail(rs);
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
