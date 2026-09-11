package com.uten.imp.features.profilechange;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.org.employee.Employee;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.profilechange.dto.ProfileChangeDto;
import com.uten.imp.application.port.HrNoticePort;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
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
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "幂等键不能为空");
        }
        // 幂等键唯一约束兜底（DB 也会拦；早返回）
        Optional<ProfileChangeRequest> existing = repo.findByIdemKey(req.idemKey());
        if (existing.isPresent()) {
            ProfileChangeRequest p = existing.get();
            return new ProfileChangeDto.SubmitResponse(
                    p.getBatchId(), List.of(p.getId()), 1);
        }

        Employee emp = employeeRepo.findById(employeeId)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "员工档案不存在"));

        UUID batchId = req.batchId() != null ? req.batchId() : UUID.randomUUID();
        OffsetDateTime now = OffsetDateTime.now();
        OffsetDateTime recentSince = now.minusHours(RECENT_WINDOW_HOURS);
        List<UUID> createdIds = new ArrayList<>();
        List<String> pendingFieldLabels = new ArrayList<>();
        int directApplied = 0;

        for (ProfileChangeDto.FieldChange ch : req.changes()) {
            ProfileFieldPolicy.assertSelfEditable(ch.fieldCode());
            if (ch.newValue() == null) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "变更后的字段值不能为空：" + ch.fieldCode());
            }

            String oldValue = applier.readCurrentValue(emp, ch.fieldCode());

            // 24h 内同字段已有 pending/approved/applied 记录 → 拒绝重复提交
            if (ProfileFieldPolicy.isRequiresReview(ch.fieldCode())
                    && repo.countRecentActiveByField(employeeId, ch.fieldCode(), recentSince) > 0) {
                throw new ApiException(ErrorCode.RATE_LIMITED,
                        "24h 内已提交过该字段的修改，请等待处理：" + ch.fieldCode());
            }

            if (ProfileFieldPolicy.isDirectEdit(ch.fieldCode())) {
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
                row.setEmployeeVersion(emp.getVersion());
                row.setIdemKey(req.idemKey() + ":" + ch.fieldCode());   // 同批次多字段不冲突
                repo.save(row);
                createdIds.add(row.getId());
                pendingFieldLabels.add(row.getFieldLabel());
            }
        }

        if (directApplied > 0) {
            emp.setVersion(emp.getVersion() + 1);
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
}
