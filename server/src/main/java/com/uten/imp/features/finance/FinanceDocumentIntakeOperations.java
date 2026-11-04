package com.uten.imp.features.finance;

import com.uten.imp.common.web.*;
import com.uten.imp.security.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.*;
import java.util.*;

/** Financial document intake families share durable request ownership, not parsing or business policy.
 * Callers keep their write permission and source-reader checks. The request lock, original source and
 * result bind atomically in the same transaction; there is no partial-commit success or default replay. */
@Service @RequiredArgsConstructor
public class FinanceDocumentIntakeOperations {
 public enum Family { AUXILIARY_STATEMENT_PREVIEW }
 private final JdbcTemplate db;private final SecurityContextCurrentUser current;private final FinanceDocumentAccessPolicy access;
 private void read(){CurrentAuthorityGuard.requireAll("finance_report:view");FinanceCompanyReportAccess.require(access);}
 @Transactional(propagation=Propagation.MANDATORY)
 public UUID existing(UUID request,Family family,String payloadHash){
  read();validate(request,family,payloadHash);db.query("SELECT pg_advisory_xact_lock(hashtextextended(?,1030))",rs->{},"uten:finance-document-intake:"+request);
  var rows=db.queryForList("SELECT actor_id,family,payload_hash,source_document_id FROM finance_document_intake_operations WHERE request_id=?",request);
  if(rows.isEmpty())return null;var old=rows.getFirst();if(!current.requireId().equals(old.get("actor_id"))||!family.name().equals(old.get("family"))||!payloadHash.equals(old.get("payload_hash")))throw conflict();return (UUID)old.get("source_document_id");
 }
 @Transactional(propagation=Propagation.MANDATORY)
 public void complete(UUID request,Family family,String payloadHash,UUID source){
  read();validate(request,family,payloadHash);if(source==null)throw new IllegalArgumentException("A confirmed source document is required");
  UUID previous=existing(request,family,payloadHash);if(previous!=null){if(!previous.equals(source))throw conflict();return;}
  db.update("INSERT INTO finance_document_intake_operations(request_id,actor_id,family,payload_hash,source_document_id)VALUES(?,?,?,?,?)",request,current.requireId(),family.name(),payloadHash,source);
 }
 @Transactional(readOnly=true)
 public UUID result(UUID request,Family family){
  read();if(request==null||family==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"请保留原导入请求编号");
  var rows=db.queryForList("SELECT source_document_id FROM finance_document_intake_operations WHERE request_id=? AND actor_id=? AND family=?",request,current.requireId(),family.name());
  if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"本人原文件导入尚未取得成功回执，请保留原请求核对");return (UUID)rows.getFirst().get("source_document_id");
 }
 private void validate(UUID request,Family family,String payload){if(request==null||family==null||payload==null||!payload.matches("[0-9a-f]{64}"))throw new ApiException(ErrorCode.VALIDATION_FAILED,"原文件导入请求或校验资料不完整");}
 private ApiException conflict(){return new ApiException(ErrorCode.CONFLICT,"原导入请求属于不同操作者、原输入或原文件，不能换内容重放");}
}
