package com.uten.imp.features.finance.asset.application;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * Production safety gate for workflows whose dedicated business-event reversal
 * path has not yet been delivered. The default is deliberately fail-closed.
 */
@Component
public final class FinanceAssetFeatureGate {

    public static final String PROPERTY = "uten.finance.asset.posted-workflows-enabled";

    private final boolean postedWorkflowsEnabled;

    public FinanceAssetFeatureGate(
            @Value("${uten.finance.asset.posted-workflows-enabled:false}") boolean postedWorkflowsEnabled) {
        this.postedWorkflowsEnabled = postedWorkflowsEnabled;
    }

    public boolean postedWorkflowsEnabled() {
        return postedWorkflowsEnabled;
    }

    public void requirePostedWorkflowsEnabled(String operation) {
        if (!postedWorkflowsEnabled) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    operation + " is disabled until the maker-checker business-event reversal workflow is enabled");
        }
    }
}
