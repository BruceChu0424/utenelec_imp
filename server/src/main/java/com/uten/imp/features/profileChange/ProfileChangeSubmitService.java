package com.uten.imp.features.profilechange;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.profilechange.dto.ProfileChangeDto;
import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.features.auth.StepUpService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.Map;
import java.util.LinkedHashMap;
import java.util.Objects;
import java.util.stream.Collectors;
import java.util.UUID;

/** 员工个人信息修改申请：提交（直改立即生效；需审核进 pending 批次，含幂等、24h 防重）。 */
@Service
@RequiredArgsConstructor
public class ProfileChangeSubmitService {

    /** 24h 内同字段防重复提交（防骚扰）。 */
    private static final long RECENT_WINDOW_HOURS = 24;

    private final ProfileChangeRepository repo;
    private final EmployeeRepository employeeRepo;
    private final ProfileFieldApplier applier;
    private final ProfileChangeSnapshotCodec snapshotCodec;
    private final ProfileChangeAccess access;
    private final TxSessionVars tx;
    private final HrNoticePort hrNotice;
    private final StepUpService stepUp;

    /**
     * 提交修改申请。一次请求里 direct 字段立即生效，review 字段进 pending 批次。
     * <p>所有字段必须经过 {@link ProfileFieldPolicy#assertSelfEditable(String)} 校验。
     */
    @Transactional
    public ProfileChangeDto.SubmitResponse submit(ProfileChangeDto.SubmitRequest req) {
        snapshotCodec.bindWriteCapability();
        // 方法首行绑定审计 actor：循环内查询会触发 JPA auto-flush，
        // 先 flush 的 INSERT 也会带上 app.actor_id（审计触发器读取）
        tx.bind();
        AuthUser user = access.requireStaff();
        UUID employeeId = user.getEmployeeId();
        if (employeeId == null) {
            throw new ApiException(ErrorCode.FORBIDDEN, "当前账号未绑定员工档案");
        }
        if (req == null || req.changes() == null || req.changes().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "变更内容不能为空");
        }
        if (req.idemKey() == null || req.idemKey().isBlank()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "提交标识缺失，请刷新页面后重新提交");
        }
        Employee emp = employeeRepo.findByIdForUpdate(employeeId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "员工档案不存在"));
        repo.lockSubmission("PROFILE-SUBMISSION:" + req.idemKey());
        Map<String, String> currentValues = new LinkedHashMap<>();
        for (var change : req.changes()) {
            if (change == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "变更字段不能为空");
            ProfileFieldPolicy.assertSelfEditable(change.fieldCode());
            if (change.newValue() == null || currentValues.containsKey(change.fieldCode())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "变更字段缺少值或重复");
            }
            currentValues.put(change.fieldCode(), applier.readCurrentValue(emp, change.fieldCode()));
        }
        // Old rows used a bare key; current multi-field rows use key:fieldCode.
        Optional<ProfileChangeRequest> existing = repo.findByIdemKey(req.idemKey());
        if (existing.isPresent()) {
            ProfileChangeRequest p = existing.get();
            if (!employeeId.equals(p.getSubmittedBy()) || !employeeId.equals(p.getEmployeeId())) {
                throw new ApiException(ErrorCode.FORBIDDEN, "提交标识不属于当前员工");
            }
            var reviewChanges = req.changes().stream()
                    .filter(change -> ProfileFieldPolicy.isRequiresReview(change.fieldCode())).toList();
            if (reviewChanges.size() != 1
                    || !p.getFieldCode().equals(reviewChanges.getFirst().fieldCode())
                    || !Objects.equals(reviewChanges.getFirst().newValue(), snapshotCodec.decode(
                            p.getFieldCode(), p.getValueEncoding(), p.getNewValueEnc()))
                    || (req.batchId() != null && !req.batchId().equals(p.getBatchId()))
                    || directRetryChanged(req, currentValues)) {
                throw new ApiException(ErrorCode.CONFLICT, "提交标识已用于另一份修改内容，请刷新后重新提交");
            }
            return new ProfileChangeDto.SubmitResponse(
                    p.getBatchId(), List.of(p.getId()), 1);
        }
        List<ProfileChangeRequest> replayRows = repo.findByIdemKeyStartingWith(req.idemKey() + ":").stream()
                .filter(row -> row.getIdemKey().equals(req.idemKey() + ":" + row.getFieldCode())).toList();
        if (!replayRows.isEmpty()) {
            UUID originalBatch = replayRows.getFirst().getBatchId();
            if (replayRows.stream().anyMatch(row -> !employeeId.equals(row.getSubmittedBy())
                    || !employeeId.equals(row.getEmployeeId()))) {
                throw new ApiException(ErrorCode.FORBIDDEN, "提交标识不属于当前员工");
            }
            Map<String, ProfileChangeRequest> byField = replayRows.stream()
                    .collect(Collectors.toMap(ProfileChangeRequest::getFieldCode, row -> row));
            var reviewChanges = req.changes().stream()
                    .filter(change -> ProfileFieldPolicy.isRequiresReview(change.fieldCode())).toList();
            if (reviewChanges.size() != replayRows.size()
                    || directRetryChanged(req, currentValues)
                    || (req.batchId() != null && !req.batchId().equals(originalBatch))
                    || replayRows.stream().anyMatch(row -> !originalBatch.equals(row.getBatchId()))
                    || reviewChanges.stream().anyMatch(change -> {
                        var row = byField.get(change.fieldCode());
                        return row == null || !Objects.equals(change.newValue(), snapshotCodec.decode(
                                row.getFieldCode(), row.getValueEncoding(), row.getNewValueEnc()));
                    })) {
                throw new ApiException(ErrorCode.CONFLICT, "提交标识已用于另一份修改内容，请刷新后重新提交");
            }
            return new ProfileChangeDto.SubmitResponse(originalBatch,
                    reviewChanges.stream().map(change -> byField.get(change.fieldCode()).getId()).toList(),
                    replayRows.size());
        }
        UUID batchId = req.batchId() != null ? req.batchId() : UUID.randomUUID();
        repo.lockSubmission("PROFILE-BATCH:" + batchId);
        if (!repo.findByBatchId(batchId).isEmpty()) {
            throw new ApiException(ErrorCode.CONFLICT, "申请批次已存在，请重新提交新的修改申请");
        }
        // 姓名、户籍地址、手机号 (即登录账号) 改动走 HR 审核, 提交前必须重新输入登录密码 (ADR-110):
        // 服务端权威校验, 不再只靠前端先问密码; 凭证在本事务内核销, 提交失败回滚时一并恢复。
        if (req.changes().stream().anyMatch(ch -> ch != null
                && ProfileFieldPolicy.REQUIRES_REVIEW.contains(ch.fieldCode()))) {
            stepUp.consumeFromCurrentRequest(user);
        }

        OffsetDateTime now = OffsetDateTime.now();
        OffsetDateTime recentSince = now.minusHours(RECENT_WINDOW_HOURS);
        List<UUID> createdIds = new ArrayList<>();
        List<String> pendingFieldLabels = new ArrayList<>();
        int directApplied = 0;
        int effectiveVersion = emp.getVersion() + (req.changes().stream().anyMatch(change ->
                ProfileFieldPolicy.isDirectEdit(change.fieldCode())
                        && !Objects.equals(currentValues.get(change.fieldCode()),
                            ProfileFieldApplier.directWriteValue(change.fieldCode(), change.newValue()))) ? 1 : 0);

        for (ProfileChangeDto.FieldChange ch : req.changes()) {
            ProfileFieldPolicy.assertSelfEditable(ch.fieldCode());
            if (ch.newValue() == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "变更后的字段值不能为空：" + ch.fieldCode());
            }

            String oldValue = currentValues.get(ch.fieldCode());

            // 24h 内同字段已有 pending/approved/applied 记录 → 拒绝重复提交
            if (ProfileFieldPolicy.isRequiresReview(ch.fieldCode())
                    && repo.countRecentActiveByField(employeeId, ch.fieldCode(), recentSince) > 0) {
                throw new ApiException(ErrorCode.RATE_LIMITED,
                        "24h 内已提交过该字段的修改，请等待处理：" + ch.fieldCode());
            }

            if (ProfileFieldPolicy.isDirectEdit(ch.fieldCode())) {
                if (Objects.equals(oldValue, ProfileFieldApplier.directWriteValue(ch.fieldCode(), ch.newValue()))) continue;
                // 直改：立即生效
                applier.applyDirectEdit(emp, ch.fieldCode(), ch.newValue());
                directApplied++;
            } else {
                // 需审核：写一行 pending
                ProfileChangeRequest row = new ProfileChangeRequest();
                row.setEmployeeId(employeeId);
                row.setBatchId(batchId);
                row.setFieldCode(ch.fieldCode());
                row.setFieldLabel(ch.fieldLabel() == null ? ch.fieldCode() : ch.fieldLabel());
                row.setFieldGroup(ProfileFieldPolicy.groupOf(ch.fieldCode()));
                row.setValueEncoding(snapshotCodec.encodingFor(ch.fieldCode()));
                row.setOldValueEnc(snapshotCodec.encode(ch.fieldCode(), oldValue));
                row.setNewValueEnc(snapshotCodec.encode(ch.fieldCode(), ch.newValue()));
                row.setStatus("pending");
                row.setSubmittedBy(employeeId);
                row.setSubmittedAt(now);
                row.setEmployeeVersion(effectiveVersion);
                row.setIdemKey(req.idemKey() + ":" + ch.fieldCode());   // 同批次多字段不冲突
                repo.save(row);
                createdIds.add(row.getId());
                pendingFieldLabels.add(row.getFieldLabel());
            }
        }

        if (directApplied > 0) {
            emp.setVersion(effectiveVersion);
            employeeRepo.save(emp);
        }
        if (!createdIds.isEmpty()) {
            // 需审核字段进批次 → 通知 HR（弹卡 + 通知；2026-09-09 人事通知接入）
            hrNotice.notifyProfileChangeSubmitted(
                    batchId,
                    emp.getFullName(),
                    pendingFieldLabels,
                    employeeId);
        }
        return new ProfileChangeDto.SubmitResponse(batchId, createdIds, createdIds.size());
    }

    // Direct fields are already applied and have no pending row snapshot.
    // A retry must agree with their current committed values, rather than
    // report success for different requested content under the old key.
    private boolean directRetryChanged(ProfileChangeDto.SubmitRequest req, Map<String, String> currentValues) {
        return req.changes().stream().anyMatch(change -> ProfileFieldPolicy.isDirectEdit(change.fieldCode())
                && !Objects.equals(currentValues.get(change.fieldCode()),
                    ProfileFieldApplier.directWriteValue(change.fieldCode(), change.newValue())));
    }
}
