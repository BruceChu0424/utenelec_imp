package com.uten.imp.features.org.employee;

import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/** New enrollment only. Names prompt review; they are never a globally unique person key. */
@Component
public class EmployeeNameReviewPolicy {
    private static final int PAGE_SIZE=100;
    private final JdbcTemplate jdbc;
    private final TxSessionVars tx;

    public EmployeeNameReviewPolicy(JdbcTemplate jdbc,TxSessionVars tx) {
        this.jdbc=jdbc;
        this.tx=tx;
    }

    /** Join the onboarding transaction so equal trimmed names serialize through the final insert/commit. */
    @Transactional(propagation=Propagation.MANDATORY)
    public void requireNewIdentity(String fullName,String idType,String document,
                                   boolean confirmedDifferentPerson,String reviewReason) {
        if(fullName==null || fullName.isBlank())
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"员工姓名不能为空");
        // SQL btrim is shared by the lock and lookup; no case folding or fuzzy name matching.
        jdbc.queryForObject("""
                SELECT pg_advisory_xact_lock(hashtextextended('employee-new-name:'||btrim(?),0))
                """,Object.class,fullName);
        UUID after=null;
        List<Candidate> page=nextPage(fullName,after);
        if(page.isEmpty())return;
        String reason=reviewReason==null?"":reviewReason.strip();
        if(!confirmedDifferentPerson || reason.codePoints().filter(c->!Character.isWhitespace(c)).count()<5)
            throw new ApiException(ErrorCode.CONFLICT,
                    "已有同名员工档案，请先核对；确为不同人员时，须明确确认并填写至少5字核验依据后再新增");
        String normalized=IdCardUtil.normalize(document);
        if(!"身份证".equals(idType) || !IdCardUtil.isValid(normalized))throw insufficientEvidence();
        for(;;) {
            for(Candidate candidate:page) {
                // A historical display type can be wrong. The complete, decrypted,
                // normalized resident document is the evidence, never its last4 or HMAC presence.
                String existing=tx.tryDecrypt(candidate.documentCipher()).map(IdCardUtil::normalize).orElse(null);
                if(!IdCardUtil.isValid(existing))throw insufficientEvidence();
                if(normalized.equals(existing))
                    throw new ApiException(ErrorCode.CONFLICT,
                            "已有同名档案使用相同证件，请使用原档案办理入职或复职，不能另建重复档案");
            }
            if(page.size()<PAGE_SIZE)return;
            after=page.getLast().employeeId();
            page=nextPage(fullName,after);
            if(page.isEmpty())return;
        }
    }

    private List<Candidate> nextPage(String fullName,UUID after) {
        return jdbc.query("""
                SELECT e.id,s.id_card_enc
                FROM employees e LEFT JOIN employee_sensitive s ON s.employee_id=e.id
                WHERE NOT e.is_deleted AND btrim(e.full_name)=btrim(?)
                  AND fn_canonical_employee_identity(e.id)=e.id
                  AND (?::uuid IS NULL OR e.id>?)
                ORDER BY e.id LIMIT ?
                """,(row,index)->new Candidate(row.getObject(1,UUID.class),row.getString(2)),
                fullName,after,after,PAGE_SIZE);
    }

    private static ApiException insufficientEvidence() {
        return new ApiException(ErrorCode.CONFLICT,
                "同名新增须以新人员及全部已有同名人员的完整有效身份证核验；资料缺失或不可读取时，请先核对已有档案");
    }

    private record Candidate(UUID employeeId,String documentCipher) { }
}
