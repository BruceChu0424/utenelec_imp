package com.uten.imp.features.org.employee;

import com.uten.imp.common.util.ChinaMobileNumber;
import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import java.util.List;
import java.util.UUID;

/**
 * One enrollment/reactivation check, including imported ciphers whose lookup
 * HMAC is absent or was calculated before online normalization. No name matching,
 * identifier backfill, plaintext logging, credential writes or identity merging.
 */
@Component
@RequiredArgsConstructor
public class EmployeeExistingIdentityGuard {
    static final String DUPLICATE_DOCUMENT_MESSAGE="该证件号码已被其他员工使用，请核对是否录错或与其他员工档案重复";
    private static final int PAGE_SIZE=100;
    private static final UUID START=new UUID(0,0);
    private final JdbcTemplate jdbc;
    private final TxSessionVars tx;
    private final EmployeeIdentityDirectory identities;
    private final EmployeeSensitiveRepository sensitive;

    public void requireCanActivate(Employee employee,EmployeeSensitive details) {
        if(details==null)return;
        String document=tx.tryDecrypt(details.getIdCardEnc())
                .map(value->comparableDocument(employee.getIdType(),value)).orElse(null);
        String phone=tx.tryDecrypt(details.getPhoneEnc()).flatMap(ChinaMobileNumber::normalize).orElse(null);
        check(employee.getId(),document,phone,true);
    }

    public void requireUnclaimedIdentity(UUID employeeId,String idType,String value) {
        check(employeeId,comparableDocument(idType,value),null,false);
    }

    public void requireUnclaimedPhone(UUID employeeId,String value) {
        check(employeeId,null,ChinaMobileNumber.normalize(value).orElse(null),false);
    }

    private void check(UUID employeeId,String document,String phone,boolean activation) {
        // Missing, invalid and unreadable identity evidence does not replace the
        // established V807 controlled enrollment path with a blanket rejection.
        if(document==null && phone==null)return;
        if(document!=null)sensitive.lockIdentityHash(tx.hmac(document));
        if(phone!=null)sensitive.lockPrimaryPhoneHash(tx.hmac(phone));
        UUID canonical=identities.canonicalEmployeeId(employeeId);
        boolean historicalClaims=Boolean.TRUE.equals(jdbc.queryForObject(
                "SELECT to_regclass('public.employee_identity_historical_claims') IS NOT NULL",Boolean.class));
        if(historicalClaims) {
            if(document!=null && historicalClaimedByOther("DOCUMENT",tx.hmac(document),canonical,employeeId))throw historicalConflict();
            if(phone!=null && historicalClaimedByOther("PHONE",tx.hmac(phone),canonical,employeeId))throw historicalConflict();
        }
        UUID after=START;
        for(;;) {
            List<Candidate> page=nextPage(canonical,after);
            for(Candidate candidate:page) {
                if(document!=null && tx.tryDecrypt(candidate.documentCipher())
                        .map(value->comparableDocument(candidate.idType(),value))
                        .filter(document::equals).isPresent()) {
                    throw conflict(true,activation);
                }
                if(phone!=null && tx.tryDecrypt(candidate.phoneCipher()).flatMap(ChinaMobileNumber::normalize)
                        .filter(phone::equals).isPresent()) {
                    throw conflict(false,activation);
                }
            }
            if(page.size()<PAGE_SIZE)return;
            after=page.getLast().employeeId();
        }
    }

    private boolean historicalClaimedByOther(String kind,String hash,UUID canonical,UUID employeeId) {
        return Boolean.TRUE.equals(jdbc.queryForObject("""
            SELECT EXISTS(SELECT 1 FROM employee_identity_historical_claims h
              WHERE h.claim_kind=? AND h.claim_hash=? AND h.canonical_employee_id<>?
                AND NOT((NOT h.ownership_verified OR h.claim_kind='PHONE')
                  AND fn_employee_merge_identifier_reviewed(?,h.claim_kind,h.claim_hash,h.source_employee_id)))
            """,Boolean.class,kind,hash,canonical,employeeId));
    }

    private static ApiException historicalConflict() {
        return new ApiException(ErrorCode.CONFLICT,"已合并旧档存在相同证件或手机号，请管理员核对历史身份凭证，不能另建副档或自动绑定");
    }

    /** Bounded keyset pages; all canonical identities and archived records are considered. */
    private List<Candidate> nextPage(UUID canonical,UUID after) {
        return jdbc.query("""
            SELECT e.id,e.id_type,s.id_card_enc,s.phone_enc
            FROM employees e JOIN employee_sensitive s ON s.employee_id=e.id
            WHERE e.id>? AND fn_canonical_employee_identity(e.id)<>?
            ORDER BY e.id LIMIT ?
            """,(rs,index)->new Candidate(rs.getObject(1,UUID.class),rs.getString(2),rs.getString(3),rs.getString(4)),
                after,canonical,PAGE_SIZE);
    }

    private static String comparableDocument(String type,String raw) {
        if(raw==null || raw.isBlank())return null;
        String resident=IdCardUtil.normalize(raw);
        // Historic resident IDs can be mislabeled as 'other'; actual normalized
        // document evidence takes precedence over that legacy display label.
        if(IdCardUtil.isValid(resident))return resident;
        if("身份证".equals(type) || "其他".equals(type))return null;
        String value=raw.strip();
        return value.length()>=6 && value.length()<=64?value:null;
    }

    private static ApiException conflict(boolean document,boolean activation) {
        if(!activation)return new ApiException(ErrorCode.CONFLICT,document?DUPLICATE_DOCUMENT_MESSAGE:"该手机号已被其他员工使用");
        String kind=document?"证件信息":"主手机号";
        return new ApiException(ErrorCode.CONFLICT,"其他历史档案存在相同"+kind+
                "，请先在人事档案中核对保留工号并处理重复，再开通账号或复职；不要另建同一人的档案");
    }
    private record Candidate(UUID employeeId,String idType,String documentCipher,String phoneCipher) { }
}
