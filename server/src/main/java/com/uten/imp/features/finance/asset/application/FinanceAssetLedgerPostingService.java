package com.uten.imp.features.finance.asset.application;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.asset.domain.AssetPeriod;
import com.uten.imp.features.finance.gl.FinanceControlledJournalService;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.YearMonth;
import java.util.List;
import java.util.UUID;

/** Asset authorization and source contract over the shared controlled journal writer. */
@Service @RequiredArgsConstructor
public class FinanceAssetLedgerPostingService {
    private final FinanceControlledJournalService journals;
    private final FinanceAssetAuthorization authorization;
    @Transactional(propagation=Propagation.MANDATORY)
    public UUID post(String voucherNo,String period,LocalDate voucherDate,String sourceType,UUID sourceDocumentId,
            String sourceDocumentType,String remark,List<Entry> entries){
        UUID actor=authorization.requireActorId(FinanceAssetAuthorization.POST);requirePeriod(period,voucherDate);
        return journals.post(voucherNo,voucherDate,sourceType,sourceDocumentId,sourceDocumentType,remark,convert(entries),actor).voucherId();
    }
    @Transactional(propagation=Propagation.MANDATORY)
    public UUID reverse(UUID originalVoucherId,String voucherNo,String period,LocalDate voucherDate,String sourceType,
            UUID sourceDocumentId,String sourceDocumentType,String reason){
        UUID actor=authorization.requireActorId(FinanceAssetAuthorization.REVERSE);requirePeriod(period,voucherDate);
        return journals.reverse(originalVoucherId,voucherNo,voucherDate,sourceType,sourceDocumentId,sourceDocumentType,reason,actor).voucherId();
    }
    static void validateEntries(List<Entry> entries){FinanceControlledJournalService.validateEntries(convert(entries));}
    private static List<FinanceControlledJournalService.Entry> convert(List<Entry> entries){
        if(entries==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请填写凭证分录");
        return entries.stream().map(e->e==null?null:new FinanceControlledJournalService.Entry(e.styleId(),e.direction(),e.amount(),e.summary())).toList();
    }
    private static void requirePeriod(String period,LocalDate date){
        AssetPeriod.parse(period);
        if(date==null||!YearMonth.from(date).toString().equals(period))throw new ApiException(ErrorCode.VALIDATION_FAILED,"凭证日期与会计期间不一致");
    }
    public record Entry(UUID styleId,int direction,BigDecimal amount,String summary) { }
}
