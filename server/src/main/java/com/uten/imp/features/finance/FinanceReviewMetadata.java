package com.uten.imp.features.finance;
import com.fasterxml.jackson.annotation.JsonInclude;
import java.util.List;
import java.util.Map;
/** HTTP review decoration only. Null properties stay absent in internal source
 * serialization, preserving original native application fingerprints. */
public class FinanceReviewMetadata extends com.uten.imp.common.history.DocumentHistoryMetadata {
    private String approvalSnapshot;
    private Long approvalVersion;
    private Map<String,List<com.uten.imp.common.platformcolumns.PlatformColumnContracts.Row>> approvalPlatformFields;
    @JsonInclude(JsonInclude.Include.NON_NULL) public String getApprovalSnapshot(){return approvalSnapshot;}
    public void setApprovalSnapshot(String value){approvalSnapshot=value;}
    @JsonInclude(JsonInclude.Include.NON_NULL) public Long getApprovalVersion(){return approvalVersion;}
    public void setApprovalVersion(Long value){approvalVersion=value;}
    @JsonInclude(JsonInclude.Include.NON_NULL) public Map<String,List<com.uten.imp.common.platformcolumns.PlatformColumnContracts.Row>> getApprovalPlatformFields(){return approvalPlatformFields;}
    public void setApprovalPlatformFields(Map<String,List<com.uten.imp.common.platformcolumns.PlatformColumnContracts.Row>> value){approvalPlatformFields=value;}
}
