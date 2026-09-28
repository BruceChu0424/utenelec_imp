package com.uten.imp.features.stock.weight;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.io.InputStream;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;

/**
 * Java 与 Flutter 端 WeightPredictor 共用的金样 (test/resources/weight/predictor_golden.json, 由参考实现
 * apw_proto.py 生成, 两边各放一份同样的文件): 称重计数、同批抽样融合、按数量核对与告警逐条对上。
 */
class ApwPredictorGoldenTest {

    private static final double REL = 1e-9;

    @Test
    void everyGoldenCaseMatchesTheReferenceImplementation() throws Exception {
        JsonNode root;
        try (InputStream in = getClass().getResourceAsStream("/weight/predictor_golden.json")) {
            assertThat(in).as("金样文件").isNotNull();
            root = new ObjectMapper().readTree(in);
        }
        JsonNode config = root.path("config");
        double gamma = config.path("gamma").asDouble();
        double scaleResKg = config.path("scaleResKg").asDouble();
        assertThat(gamma).isEqualTo(EstimatorConfig.DEFAULT_GAMMA);
        assertThat(scaleResKg).isEqualTo(EstimatorConfig.DEFAULT_SCALE_RES_KG);
        for (Map.Entry<String, JsonNode> eps : config.path("eps").properties()) {
            assertThat(SourceKind.parse(eps.getKey()).eps()).as("eps " + eps.getKey())
                    .isEqualTo(eps.getValue().asDouble());
        }

        int checked = 0;
        for (JsonNode c : root.path("cases")) {
            String name = c.path("name").asText();
            JsonNode p = c.path("params");
            ApwPredictor.Params params = new ApwPredictor.Params(p.path("logMean").asDouble(),
                    p.path("lotPrior").asDouble(), p.path("df").asDouble(), gamma, scaleResKg);
            JsonNode expect = c.path("expect");
            switch (c.path("op").asText()) {
                case "count" -> {
                    JsonNode s = c.path("sample");
                    ApwPredictor.Sample sample = s.isMissingNode() || s.isNull() ? null
                            : new ApwPredictor.Sample(s.path("qty").asDouble(), s.path("weightKg").asDouble());
                    ApwPredictor.CountPrediction r = ApwPredictor.countFromWeight(params,
                            c.path("weightKg").asDouble(), sample);
                    close(name, "estimatedQty", r.estimatedQty(), expect);
                    close(name, "qtyLow", r.qtyLow(), expect);
                    close(name, "qtyHigh", r.qtyHigh(), expect);
                    close(name, "logHalfWidth", r.logHalfWidth(), expect);
                    close(name, "relHalfWidth", r.relHalfWidth(), expect);
                    close(name, "exactUpToQty", r.exactUpToQty(), expect);
                    close(name, "fusedLogMean", r.fusedLogMean(), expect);
                    close(name, "fusedLotPrior", r.fusedLotPrior(), expect);
                }
                case "expected" -> {
                    SourceKind kind = SourceKind.parse(c.path("kind").asText());
                    ApwPredictor.WeightCheck r = ApwPredictor.checkWeight(params, kind.eps(),
                            c.path("qty").asDouble(), c.path("weightKg").asDouble(),
                            c.path("tolerancePct").asDouble());
                    close(name, "expectedWeightKg", r.expectedWeightKg(), expect);
                    close(name, "deviationPct", r.deviationPct(), expect);
                    close(name, "z", r.z(), expect);
                    assertThat(r.alert().name()).as(name + " alert").isEqualTo(expect.path("alert").asText());
                }
                default -> throw new AssertionError("unknown op in " + name);
            }
            checked++;
        }
        assertThat(checked).as("金样条数").isGreaterThanOrEqualTo(17);
    }

    private static void close(String name, String field, double actual, JsonNode expect) {
        double expected = expect.path(field).asDouble();
        assertThat(actual).as(name + " " + field).isCloseTo(expected, within(Math.abs(expected) * REL + 1e-15));
    }
}
