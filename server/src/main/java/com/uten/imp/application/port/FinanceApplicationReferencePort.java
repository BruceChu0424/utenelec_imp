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
    record Reference(String type,UUID documentId,BigDecimal amount,LocalDate paymentDate,UUID supplierId,AuthUser actor,
            NativeApplicationOriginPort.AmountBasis amountBasis,UUID currencyId,List<NativeApplicationOriginPort.Obligation> obligations,UUID applicationId){
        public Reference {amountBasis=amountBasis==null?NativeApplicationOriginPort.AmountBasis.LOCAL:amountBasis;obligations=obligations==null?List.of():List.copyOf(obligations);}
        public Reference(String type,UUID documentId,BigDecimal amount,LocalDate paymentDate,UUID supplierId,AuthUser actor){this(type,documentId,amount,paymentDate,supplierId,actor,NativeApplicationOriginPort.AmountBasis.LOCAL,null,List.of(),null);}
        public Reference(String type,UUID documentId,BigDecimal amount,LocalDate paymentDate,UUID supplierId,AuthUser actor,NativeApplicationOriginPort.AmountBasis amountBasis,UUID currencyId,List<NativeApplicationOriginPort.Obligation> obligations){this(type,documentId,amount,paymentDate,supplierId,actor,amountBasis,currencyId,obligations,null);}
    }
    record Condition(String sql,Map<String,Object> parameters){}
    record Candidate(UUID id,String billNo,LocalDate billDate,BigDecimal amount,NativeApplicationOriginPort.AmountBasis amountBasis,String currencyCode){
        public Candidate(UUID id,String billNo,LocalDate billDate,BigDecimal amount){this(id,billNo,billDate,amount,NativeApplicationOriginPort.AmountBasis.LOCAL,null);}
    }
    record CandidatePage(List<Candidate> items,long total){}
}
