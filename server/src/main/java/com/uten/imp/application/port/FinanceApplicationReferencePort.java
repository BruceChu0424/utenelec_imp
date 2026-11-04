package com.uten.imp.application.port;
import com.uten.imp.security.AuthUser;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;
import java.util.List;
import java.util.Map;
/** Finance owns audited posting identity, scope and exact accounting facts. Never reposts money. */
public interface FinanceApplicationReferencePort {
    void requireApprovedMatch(Reference reference);
    void requireApprovedPrepaymentMatch(Reference reference);
    Condition prepaymentMatchingCondition(String applicationAlias,AuthUser actor);
    CandidatePage prepaymentCandidates(UUID applicationId,UUID supplierId,BigDecimal amount,LocalDate paymentDate,AuthUser actor,int page,int size,String keyword);
    record Reference(String type,UUID documentId,BigDecimal amount,LocalDate paymentDate,UUID supplierId,AuthUser actor){}
    record Condition(String sql,Map<String,Object> parameters){}
    record Candidate(UUID id,String billNo,LocalDate billDate,BigDecimal amount){}
    record CandidatePage(List<Candidate> items,long total){}
}
