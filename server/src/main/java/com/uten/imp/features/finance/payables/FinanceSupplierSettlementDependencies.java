package com.uten.imp.features.finance.payables;

import com.uten.imp.common.web.*;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.util.*;

/** Exact write-time ordering while the caller holds the common AP locks; no timestamp or name inference. */
@Service @RequiredArgsConstructor
public class FinanceSupplierSettlementDependencies {
    private final JdbcTemplate db;
    private final SecurityContextCurrentUser current;
    @Transactional(propagation=Propagation.MANDATORY)
    public void paymentApproved(UUID paymentId) {
        db.update("""
                INSERT INTO finance_supplier_settlement_dependencies(payment_line_id,offset_id,ledger_id,relation,source_snapshot,created_by)
                SELECT line.id,offset_row.id,line.applied_ledger_id,'OFFSET_BEFORE_PAYMENT',
                    jsonb_build_object('basis','已持有同一应付锁，付款审核时抵销已生效','paymentId',payment.id,'paymentBillNo',payment.bill_no,
                        'offsetId',offset_row.id,'offsetBatchId',offset_row.offset_batch_id,'ledgerId',line.applied_ledger_id,
                        'paymentBeforeOriginal',line.balance_before_original,'paymentAfterOriginal',line.balance_after_original,
                        'offsetBeforeOriginal',offset_row.target_balance_before_original,'offsetAfterOriginal',offset_row.target_balance_after_original),?
                FROM finance_payment_lines line JOIN finance_payments payment ON payment.id=line.payment_id
                JOIN supplier_open_item_offsets offset_row ON offset_row.target_ledger_id=line.applied_ledger_id OR offset_row.source_ledger_id=line.applied_ledger_id
                WHERE payment.id=? AND payment.status=1 AND NOT payment.is_deleted AND NOT line.is_deleted
                  AND payment.settlement_approved_tx=pg_current_xact_id() AND offset_row.status='APPLIED'
                ON CONFLICT DO NOTHING
                """,current.requireId(),paymentId);
        db.update("""
            INSERT INTO finance_supplier_advance_dependencies(application_id,payment_line_id,relation,created_by)
            SELECT application.id,line.id,'APPLICATION_BEFORE_PEER',? FROM finance_payment_lines line
            JOIN finance_payments payment ON payment.id=line.payment_id
            JOIN finance_supplier_advance_applications application ON application.target_ledger_id=line.applied_ledger_id
            WHERE payment.id=? AND payment.status=1 AND payment.settlement_approved_tx=pg_current_xact_id()
              AND NOT payment.is_deleted AND NOT line.is_deleted AND application.status='APPLIED' ON CONFLICT DO NOTHING
            """,current.requireId(),paymentId);
    }
    @Transactional(propagation=Propagation.MANDATORY)
    public void offsetApplied(UUID offsetId) {
        db.update("""
                INSERT INTO finance_supplier_settlement_dependencies(payment_line_id,offset_id,ledger_id,relation,source_snapshot,created_by)
                SELECT line.id,offset_row.id,line.applied_ledger_id,'PAYMENT_BEFORE_OFFSET',
                    jsonb_build_object('basis','已持有同一应付锁，抵销写入时付款已审核','paymentId',payment.id,'paymentBillNo',payment.bill_no,
                        'offsetId',offset_row.id,'offsetBatchId',offset_row.offset_batch_id,'ledgerId',line.applied_ledger_id,
                        'paymentBeforeOriginal',line.balance_before_original,'paymentAfterOriginal',line.balance_after_original,
                        'offsetBeforeOriginal',offset_row.target_balance_before_original,'offsetAfterOriginal',offset_row.target_balance_after_original),?
                FROM supplier_open_item_offsets offset_row
                JOIN finance_payment_lines line ON line.applied_ledger_id IN(offset_row.source_ledger_id,offset_row.target_ledger_id)
                JOIN finance_payments payment ON payment.id=line.payment_id
                WHERE offset_row.id=? AND offset_row.status='APPLIED' AND offset_row.settlement_created_tx=pg_current_xact_id()
                  AND payment.status=1 AND NOT payment.is_deleted AND NOT line.is_deleted
                ON CONFLICT DO NOTHING
                """,current.requireId(),offsetId);
        db.update("""
            INSERT INTO finance_supplier_advance_dependencies(application_id,offset_id,relation,created_by)
            SELECT application.id,offset_row.id,'APPLICATION_BEFORE_PEER',? FROM supplier_open_item_offsets offset_row
            JOIN finance_supplier_advance_applications application ON application.target_ledger_id IN(offset_row.source_ledger_id,offset_row.target_ledger_id)
            WHERE offset_row.id=? AND offset_row.status='APPLIED' AND offset_row.settlement_created_tx=pg_current_xact_id()
              AND application.status='APPLIED' ON CONFLICT DO NOTHING
            """,current.requireId(),offsetId);
    }
    @Transactional(propagation=Propagation.MANDATORY)
    public void advanceApplied(UUID id) {
        db.update("""
            INSERT INTO finance_supplier_advance_dependencies(application_id,payment_line_id,relation,created_by)
            SELECT application.id,line.id,'PEER_BEFORE_APPLICATION',? FROM finance_supplier_advance_applications application
            JOIN finance_payment_lines line ON line.applied_ledger_id=application.target_ledger_id
            JOIN finance_payments payment ON payment.id=line.payment_id
            WHERE application.id=? AND application.status='APPLIED' AND payment.status=1 AND NOT payment.is_deleted AND NOT line.is_deleted ON CONFLICT DO NOTHING
            """,current.requireId(),id);
        db.update("""
            INSERT INTO finance_supplier_advance_dependencies(application_id,offset_id,relation,created_by)
            SELECT application.id,offset_row.id,'PEER_BEFORE_APPLICATION',? FROM finance_supplier_advance_applications application
            JOIN supplier_open_item_offsets offset_row ON application.target_ledger_id IN(offset_row.source_ledger_id,offset_row.target_ledger_id)
            WHERE application.id=? AND application.status='APPLIED' AND offset_row.status='APPLIED' ON CONFLICT DO NOTHING
            """,current.requireId(),id);
    }
    @Transactional(propagation=Propagation.MANDATORY,readOnly=true,noRollbackFor=ApiException.class)
    public void requirePaymentReversible(UUID paymentId) {
        var rows=db.queryForList("""
                SELECT offset_row.id,offset_row.offset_batch_id,ledger.bill_no
                FROM finance_supplier_settlement_dependencies dependency
                JOIN finance_payment_lines line ON line.id=dependency.payment_line_id
                JOIN supplier_open_item_offsets offset_row ON offset_row.id=dependency.offset_id
                JOIN ar_ap_ledger ledger ON ledger.id=dependency.ledger_id
                WHERE line.payment_id=? AND dependency.relation='PAYMENT_BEFORE_OFFSET' AND offset_row.status='APPLIED'
                ORDER BY offset_row.created_at,offset_row.id LIMIT 5
                """,paymentId);
        if(!rows.isEmpty())throw new ApiException(ErrorCode.CONFLICT,"该付款之后仍有生效的供应商抵销，请先撤回后抵销："+
                String.join("；",rows.stream().map(row->"应付"+row.get("bill_no")+"，抵销记录"+row.get("id")).toList()));
        var advances=db.queryForList("""
            SELECT application.id FROM finance_supplier_advance_dependencies dependency JOIN finance_supplier_advance_applications application ON application.id=dependency.application_id
            JOIN finance_payment_lines line ON line.id=dependency.payment_line_id
            WHERE line.payment_id=? AND dependency.relation='PEER_BEFORE_APPLICATION' AND application.status='APPLIED' ORDER BY application.id LIMIT 5
            """,paymentId);
        if(!advances.isEmpty())throw new ApiException(ErrorCode.CONFLICT,"该付款之后仍有预付应用，请先撤回后预付应用："+advances.stream().map(row->row.get("id").toString()).toList());
    }
    @Transactional(propagation=Propagation.MANDATORY,readOnly=true,noRollbackFor=ApiException.class)
    public void requireOffsetReversible(UUID offsetBatchId) {
        var rows=db.queryForList("""
                SELECT DISTINCT payment.id,payment.bill_no
                FROM finance_supplier_settlement_dependencies dependency
                JOIN supplier_open_item_offsets offset_row ON offset_row.id=dependency.offset_id
                JOIN finance_payment_lines line ON line.id=dependency.payment_line_id
                JOIN finance_payments payment ON payment.id=line.payment_id
                WHERE offset_row.offset_batch_id=? AND dependency.relation='OFFSET_BEFORE_PAYMENT'
                  AND payment.status=1 AND NOT payment.is_deleted AND NOT line.is_deleted
                ORDER BY payment.bill_no,payment.id LIMIT 5
                """,offsetBatchId);
        if(!rows.isEmpty())throw new ApiException(ErrorCode.CONFLICT,"该抵销之后仍有已审核付款，请先反审后付款："+
                String.join("；",rows.stream().map(row->row.get("bill_no")+"（"+row.get("id")+"）").toList()));
        var advances=db.queryForList("""
            SELECT application.id FROM finance_supplier_advance_dependencies dependency JOIN finance_supplier_advance_applications application ON application.id=dependency.application_id
            JOIN supplier_open_item_offsets offset_row ON offset_row.id=dependency.offset_id
            WHERE offset_row.offset_batch_id=? AND dependency.relation='PEER_BEFORE_APPLICATION' AND application.status='APPLIED' ORDER BY application.id LIMIT 5
            """,offsetBatchId);
        if(!advances.isEmpty())throw new ApiException(ErrorCode.CONFLICT,"该抵销之后仍有预付应用，请先撤回后预付应用："+advances.stream().map(row->row.get("id").toString()).toList());
    }

    @Transactional(propagation=Propagation.MANDATORY,readOnly=true,noRollbackFor=ApiException.class)
    public void requireAdvanceReversible(UUID id){
        var count=db.queryForObject("""
            SELECT count(*) FROM finance_supplier_advance_dependencies dependency
            LEFT JOIN finance_payment_lines line ON line.id=dependency.payment_line_id LEFT JOIN finance_payments payment ON payment.id=line.payment_id
            LEFT JOIN supplier_open_item_offsets offset_row ON offset_row.id=dependency.offset_id
            WHERE dependency.application_id=? AND dependency.relation='APPLICATION_BEFORE_PEER'
              AND ((payment.status=1 AND NOT payment.is_deleted AND NOT line.is_deleted) OR offset_row.status='APPLIED')
            """,Integer.class,id);
        if(count!=null&&count>0)throw new ApiException(ErrorCode.CONFLICT,"预付应用之后仍有生效的付款或抵销，请先撤回后续事实");
    }
}
