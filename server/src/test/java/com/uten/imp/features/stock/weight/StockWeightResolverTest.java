package com.uten.imp.features.stock.weight;

import com.uten.imp.features.stock.StockService;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * ADR-135 仓库重量账纯计算的场景表(spec §9 第一条)。每个场景都在一本内存小账上逐笔过账, 每一笔之后核对:
 * 账链连续(调整行的「前」= 上一行的「后」; 流水行「前 +/- 本笔重量 = 后」; 最后一行的「后」= 余额重量)、
 * 余额守库级约束(重量未知, 或数量 0 且重量 0, 或数量大于 0 且重量大于 0)、流水与调整行的「后」都不为负。
 */
class StockWeightResolverTest {

    private static final UUID GOODS = UUID.randomUUID();
    private static final UUID MAIN = UUID.randomUUID();
    private static final UUID SIDE = UUID.randomUUID();
    private static final short TRANSFER_OUT = 8;
    private static final short TRANSFER_IN = 7;
    private static final short OTHER_IN = 11;
    private static final short SALES_OUT = 3;
    private static final short DRAW = 5;
    private static final short CHECK_GAIN = 9;

    // ===== 场景 =====

    @Test
    void zeroCrossingInboundWithoutUnitWeightLeavesWeightUnknownInsteadOfZero() {
        Book book = new Book();
        book.seed(MAIN, "0", "0.0000");
        var in = book.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "10", null));

        assertThat(in.weightKg()).isNull();
        assertThat(in.source()).isNull();
        assertThat(book.dim(MAIN).weight).isNull();
        assertThat(book.dim(MAIN).estimated).isFalse();

        // 发完: 重量重新成为已知的 0, 流水行直接记 0, 不另写调整行。
        var out = book.post(request(SALES_OUT, StockService.DIR_OUT, MAIN, "10", null));
        assertThat(out.weightKg()).isNull();
        assertThat(out.before()).isEmpty();
        assertKg(out.balanceWeightAfter(), "0");
        assertKg(book.dim(MAIN).weight, "0");
    }

    @Test
    void transferFromUnknownSourceIntoKnownDestinationTakesDestinationAverage() {
        Book book = new Book();
        book.seed(MAIN, "10", null);
        book.seed(SIDE, "20", "8.0000");
        UUID doc = UUID.randomUUID();
        UUID item = UUID.randomUUID();

        var out = book.post(request(TRANSFER_OUT, StockService.DIR_OUT, MAIN, "5", null, doc, item));
        var in = book.post(request(TRANSFER_IN, StockService.DIR_IN, SIDE, "5", null, doc, item));

        assertThat(out.weightKg()).isNull();
        assertThat(book.dim(MAIN).weight).isNull();
        assertKg(in.weightKg(), "2.0000");
        assertThat(in.source()).isEqualTo(WeightSource.AVERAGE);
        assertKg(book.dim(SIDE).weight, "10.0000");
        assertThat(book.dim(SIDE).estimated).isTrue();
    }

    @Test
    void transferInMirrorsTheOutLegAndItsReversalRestoresBothSidesExactly() {
        Book book = new Book();
        book.seed(MAIN, "10", "5.0000");
        UUID doc = UUID.randomUUID();
        UUID item = UUID.randomUUID();

        book.post(request(TRANSFER_OUT, StockService.DIR_OUT, MAIN, "4", CapturedWeight.measured(new BigDecimal("2.2")),
                doc, item));
        var in = book.post(request(TRANSFER_IN, StockService.DIR_IN, SIDE, "4", null, doc, item));
        assertKg(in.weightKg(), "2.2000");
        assertThat(in.source()).isEqualTo(WeightSource.MEASURED);
        assertKg(book.dim(MAIN).weight, "2.8000");
        assertKg(book.dim(SIDE).weight, "2.2000");

        // 红冲顺序与正向相反: 先在原仓调回(8 入), 再从目的仓调出(7 出), 两腿都按各自原流水镜像。
        var back = book.post(request(TRANSFER_OUT, StockService.DIR_IN, MAIN, "4", null, doc, item));
        var away = book.post(request(TRANSFER_IN, StockService.DIR_OUT, SIDE, "4", null, doc, item));
        assertKg(back.weightKg(), "2.2000");
        assertKg(away.weightKg(), "2.2000");
        assertKg(book.dim(MAIN).weight, "5.0000");
        assertKg(book.dim(SIDE).weight, "0");
        assertThat(away.before()).isEmpty();
    }

    @Test
    void reversalAfterLaterMovementsMirrorsTheOriginalAndSettlesTheResidualAtZero() {
        Book book = new Book();
        UUID docA = UUID.randomUUID();
        UUID itemA = UUID.randomUUID();
        book.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "10", CapturedWeight.measured(new BigDecimal("5")),
                docA, itemA));
        var sold = book.post(request(SALES_OUT, StockService.DIR_OUT, MAIN, "5", null));
        assertKg(sold.weightKg(), "2.5000");
        assertThat(sold.source()).isEqualTo(WeightSource.AVERAGE);
        book.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "5", CapturedWeight.measured(new BigDecimal("3.5"))));
        assertKg(book.dim(MAIN).weight, "6.0000");

        var reversal = book.post(request(OTHER_IN, StockService.DIR_OUT, MAIN, "10", null, docA, itemA));

        assertKg(reversal.weightKg(), "5.0000");
        assertThat(reversal.source()).isEqualTo(WeightSource.MEASURED);
        // 数量归零还剩 1 kg 零头: 尾差行先把 6 纠正到 5, 红冲 5 后正好是 0。
        assertThat(reversal.before()).singleElement().satisfies(residual -> {
            assertThat(residual.kind()).isEqualTo("RESIDUAL");
            assertKg(residual.before(), "6.0000");
            assertKg(residual.after(), "5.0000");
            assertKg(residual.deltaKg(), "-1.0000");
        });
        assertKg(reversal.balanceWeightAfter(), "0");
        assertThat(book.dim(MAIN).estimated).isFalse();
    }

    @Test
    void partialDrawCancelsMirrorProRataAndTheFinalCancelSweepsTheRemainder() {
        Book book = new Book();
        book.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "100", CapturedWeight.measured(new BigDecimal("50"))));
        UUID draw = UUID.randomUUID();
        UUID line = UUID.randomUUID();
        book.post(request(DRAW, StockService.DIR_OUT, MAIN, "10", CapturedWeight.measured(new BigDecimal("5.3")),
                draw, line));
        book.post(request(DRAW, StockService.DIR_OUT, MAIN, "5", CapturedWeight.measured(new BigDecimal("2.6")),
                draw, line));
        assertKg(book.dim(MAIN).weight, "42.1000");

        var first = book.post(request(DRAW, StockService.DIR_IN, MAIN, "8", null, draw, line));
        var last = book.post(request(DRAW, StockService.DIR_IN, MAIN, "7", null, draw, line));

        assertKg(first.weightKg(), "4.2133");
        assertKg(last.weightKg(), "3.6867");
        assertThat(last.source()).isEqualTo(WeightSource.MEASURED);
        assertKg(book.dim(MAIN).weight, "50.0000");
        assertThat(book.dim(MAIN).estimated).isFalse();
    }

    @Test
    void countWeightWithZeroSurplusAndItsReversalRestoreThePreCountWeight() {
        Book book = new Book();
        book.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "10", CapturedWeight.measured(new BigDecimal("4.5"))));
        Count count = book.count(MAIN, "4.8");
        var sold = book.post(request(SALES_OUT, StockService.DIR_OUT, MAIN, "2", null));
        assertKg(sold.weightKg(), "0.9600");
        assertKg(book.dim(MAIN).weight, "3.8400");

        book.reverseCount(MAIN, count);

        assertKg(book.dim(MAIN).weight, "3.5400");
        assertThat(book.dim(MAIN).estimated).isFalse();
    }

    @Test
    void checkWithSurplusThenCountIsFullyUndoneByMirrorAndCountReversal() {
        Book book = new Book();
        book.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "10", CapturedWeight.measured(new BigDecimal("4.5"))));
        UUID check = UUID.randomUUID();
        UUID line = UUID.randomUUID();
        var surplus = book.post(request(CHECK_GAIN, StockService.DIR_IN, MAIN, "2", null, check, line));
        assertKg(surplus.weightKg(), "0.9000");
        assertThat(book.dim(MAIN).estimated).isTrue();
        Count count = book.count(MAIN, "5.7");
        assertThat(book.dim(MAIN).estimated).isFalse();

        var mirror = book.post(request(CHECK_GAIN, StockService.DIR_OUT, MAIN, "2", null, check, line));
        assertKg(mirror.weightKg(), "0.9000");
        assertThat(mirror.source()).isEqualTo(WeightSource.AVERAGE);
        book.reverseCount(MAIN, count);

        assertKg(book.dim(MAIN).qty, "10");
        assertKg(book.dim(MAIN).weight, "4.5000");
    }

    @Test
    void countReversalWithUnknownPreCountWeightKeepsWeightButMarksItEstimated() {
        StockWeightResolver.CountReversal kept = StockWeightResolver.reverseCount(
                new BigDecimal("10"), new BigDecimal("4.8000"), false, null, new BigDecimal("4.8000"));
        assertKg(kept.weightAfter(), "4.8000");
        assertThat(kept.estimatedAfter()).isTrue();

        StockWeightResolver.CountReversal empty = StockWeightResolver.reverseCount(
                BigDecimal.ZERO, new BigDecimal("0"), false, new BigDecimal("1"), new BigDecimal("2"));
        assertKg(empty.weightAfter(), "0");

        StockWeightResolver.CountReversal wiped = StockWeightResolver.reverseCount(
                new BigDecimal("3"), new BigDecimal("0.2000"), false, new BigDecimal("1"), new BigDecimal("2"));
        assertThat(wiped.weightAfter()).isNull();
    }

    @Test
    void inboundOntoNegativeLegacyQuantityReAnchorsOnTheMovementRow() {
        Book book = new Book();
        book.seed(MAIN, "-5", null);

        var in = book.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "10", CapturedWeight.measured(new BigDecimal("4"))));

        assertKg(in.weightKg(), "4.0000");
        assertThat(in.before()).isEmpty();
        assertKg(in.balanceWeightAfter(), "2.0000");
        assertThat(book.dim(MAIN).estimated).isTrue();

        Book toZero = new Book();
        toZero.seed(MAIN, "-5", null);
        toZero.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "5", CapturedWeight.measured(new BigDecimal("2"))));
        assertKg(toZero.dim(MAIN).weight, "0");
        assertThat(toZero.dim(MAIN).estimated).isFalse();
    }

    @Test
    void exactGoodsRewriteTheBalanceAbsolutelyWithoutAnchorOrResidual() {
        Book book = new Book();
        book.goodsFactor = new BigDecimal("0.028349523125"); // 盎司
        book.seed(MAIN, "0", "7.0000"); // 旧的错重量直接被整值改写, 不补起算行

        var first = book.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "1", CapturedWeight.measured(new BigDecimal("9"))));
        var second = book.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "1", null));

        assertKg(first.weightKg(), "0.0283");
        assertThat(first.source()).isEqualTo(WeightSource.EXACT);
        assertKg(second.weightKg(), "0.0283");
        // 余额按总数量整值换算(0.0567), 不是逐笔累加(0.0566)。
        assertKg(book.dim(MAIN).weight, "0.0567");
        var out = book.post(request(SALES_OUT, StockService.DIR_OUT, MAIN, "2", null));
        assertKg(out.weightKg(), "0.0567");
        assertKg(book.dim(MAIN).weight, "0");
        assertThat(first.before()).isEmpty();
        assertThat(out.before()).isEmpty();
        assertThat(book.dim(MAIN).estimated).isFalse();
    }

    @Test
    void zeroSliceStaysOnTheMovementWhileTheBalanceFallsBackToUnknownOrEstimate() {
        Book unknown = new Book();
        var zero = unknown.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "10", CapturedWeight.slice(BigDecimal.ZERO)));
        assertKg(zero.weightKg(), "0");
        assertThat(zero.source()).isEqualTo(WeightSource.SLICE);
        assertThat(zero.before()).isEmpty();
        assertThat(unknown.dim(MAIN).weight).isNull();

        Book estimated = new Book();
        estimated.apw = new UnitWeightLookup.UnitWeightRef(new BigDecimal("0.5"), "LEARNED", "GREEN");
        var zeroWithApw = estimated.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "10",
                CapturedWeight.slice(BigDecimal.ZERO)));
        assertKg(zeroWithApw.weightKg(), "0");
        assertThat(zeroWithApw.before()).singleElement().satisfies(residual -> {
            assertThat(residual.kind()).isEqualTo("RESIDUAL");
            assertKg(residual.before(), "0");
            assertKg(residual.after(), "5.0000");
        });
        assertKg(estimated.dim(MAIN).weight, "5.0000");
        assertThat(estimated.dim(MAIN).estimated).isTrue();
    }

    @Test
    void massLineUnitIsExactFromLineQuantity() {
        Book book = new Book();
        book.lineFactor = BigDecimal.ONE; // 按千克买, 换算率 20 件/千克
        var in = book.post(new StockService.MovementRequest(OffsetDateTime.now(), OTHER_IN, "STOCK_DOC",
                UUID.randomUUID(), UUID.randomUUID(), GOODS, null, MAIN, StockService.DIR_IN, new BigDecimal("100"),
                UUID.randomUUID(), new BigDecimal("20"), null, null, CapturedWeight.measured(new BigDecimal("6"))));

        assertKg(in.weightKg(), "5.0000");
        assertThat(in.source()).isEqualTo(WeightSource.EXACT);
        assertKg(book.dim(MAIN).weight, "5.0000");
        assertThat(book.dim(MAIN).estimated).isFalse();
    }

    @Test
    void unweighedInboundPrefersConfidentUnitWeightOverBookAverage() {
        Book green = new Book();
        green.apw = new UnitWeightLookup.UnitWeightRef(new BigDecimal("0.5"), "LEARNED", "GREEN");
        green.seed(MAIN, "10", "4.0000");
        var byUnitWeight = green.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "10", null));
        assertKg(byUnitWeight.weightKg(), "5.0000");
        assertThat(byUnitWeight.source()).isEqualTo(WeightSource.ESTIMATE);
        assertKg(green.dim(MAIN).weight, "9.0000");
        assertThat(green.dim(MAIN).estimated).isTrue();

        Book red = new Book();
        red.apw = new UnitWeightLookup.UnitWeightRef(new BigDecimal("0.5"), "MASTER_PRIOR", "RED");
        red.seed(MAIN, "10", "4.0000");
        var byAverage = red.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "10", null));
        assertKg(byAverage.weightKg(), "4.0000");
        assertThat(byAverage.source()).isEqualTo(WeightSource.AVERAGE);

        Book empty = new Book();
        empty.apw = new UnitWeightLookup.UnitWeightRef(new BigDecimal("0.5"), "MASTER_PRIOR", "RED");
        var byAnyUnitWeight = empty.post(request(OTHER_IN, StockService.DIR_IN, MAIN, "10", null));
        assertKg(byAnyUnitWeight.weightKg(), "5.0000");
        assertThat(byAnyUnitWeight.source()).isEqualTo(WeightSource.ESTIMATE);
    }

    @Test
    void outboundSweepTakesTheWholeBookWeight() {
        Book book = new Book();
        book.seed(MAIN, "3", "1.0000");
        var out = book.post(request(SALES_OUT, StockService.DIR_OUT, MAIN, "3", null));
        assertKg(out.weightKg(), "1.0000");
        assertThat(out.source()).isEqualTo(WeightSource.AVERAGE);
        assertThat(out.before()).isEmpty();
        assertKg(book.dim(MAIN).weight, "0");
    }

    @Test
    void weighedOutboundFromUnknownBookAnchorsBeforeTheMovement() {
        Book byMovement = new Book();
        byMovement.seed(MAIN, "10", null);
        var out = byMovement.post(request(SALES_OUT, StockService.DIR_OUT, MAIN, "4",
                CapturedWeight.measured(new BigDecimal("2"))));
        assertThat(out.before()).singleElement().satisfies(anchor -> {
            assertThat(anchor.kind()).isEqualTo("ANCHOR");
            assertThat(anchor.before()).isNull();
            assertKg(anchor.after(), "5.0000");
        });
        assertKg(byMovement.dim(MAIN).weight, "3.0000");
        assertThat(byMovement.dim(MAIN).estimated).isTrue();

        Book byUnitWeight = new Book();
        byUnitWeight.apw = new UnitWeightLookup.UnitWeightRef(new BigDecimal("0.4"), "LEARNED", "YELLOW");
        byUnitWeight.seed(MAIN, "10", null);
        byUnitWeight.post(request(SALES_OUT, StockService.DIR_OUT, MAIN, "4",
                CapturedWeight.measured(new BigDecimal("2"))));
        assertKg(byUnitWeight.dim(MAIN).weight, "2.0000");
    }

    @Test
    void outboundHeavierThanBookCorrectsBeforeTheMovementAndReEstimatesTheRemainder() {
        Book book = new Book();
        book.seed(MAIN, "10", "4.5000");
        var out = book.post(request(SALES_OUT, StockService.DIR_OUT, MAIN, "1",
                CapturedWeight.measured(new BigDecimal("5"))));
        assertThat(out.before()).singleElement().satisfies(residual -> {
            assertThat(residual.kind()).isEqualTo("RESIDUAL");
            assertKg(residual.before(), "4.5000");
            assertKg(residual.after(), "50.0000");
        });
        assertKg(out.balanceWeightAfter(), "45.0000");
        assertThat(book.dim(MAIN).estimated).isTrue();
    }

    @Test
    void mirroredEstimateOnInboundKeepsTheBalanceEstimated() {
        Book book = new Book();
        book.seed(MAIN, "10", "4.0000");
        UUID doc = UUID.randomUUID();
        UUID item = UUID.randomUUID();
        book.post(request(SALES_OUT, StockService.DIR_OUT, MAIN, "5", null, doc, item));
        var back = book.post(request(SALES_OUT, StockService.DIR_IN, MAIN, "5", null, doc, item));
        assertKg(back.weightKg(), "2.0000");
        assertThat(back.source()).isEqualTo(WeightSource.AVERAGE);
        assertThat(book.dim(MAIN).estimated).isTrue();
    }

    @Test
    void capturedWeightRejectsNegativesAndTreatsZeroMeasurementAsNotWeighed() {
        assertThat(CapturedWeight.measured(BigDecimal.ZERO)).isNull();
        assertThat(CapturedWeight.measured(null)).isNull();
        assertThat(CapturedWeight.slice(BigDecimal.ZERO)).isNotNull();
        assertThatThrownBy(() -> CapturedWeight.slice(new BigDecimal("-1")))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new CapturedWeight(BigDecimal.ONE, WeightSource.AVERAGE))
                .isInstanceOf(IllegalArgumentException.class);
        assertThat(CapturedWeight.measured(new BigDecimal("1.234567")).kg()).isEqualByComparingTo("1.2346");
        assertThat(CapturedWeight.measured(new BigDecimal("1.2300000")).kg().scale()).isLessThanOrEqualTo(4);
        assertThat(WeightSource.weakest(WeightSource.MEASURED, WeightSource.AVERAGE)).isEqualTo(WeightSource.AVERAGE);
        assertThat(WeightSource.weakest(WeightSource.SLICE, WeightSource.EXACT)).isEqualTo(WeightSource.EXACT);
    }

    // ===== 内存小账 =====

    private record Count(BigDecimal before, BigDecimal after) {
    }

    private record Posted(StockService.MovementRequest request, BigDecimal kg, WeightSource source) {
    }

    private static final class Dim {
        BigDecimal qty = BigDecimal.ZERO;
        BigDecimal weight;
        boolean estimated;
        boolean exists;
        BigDecimal chainAfter;
        boolean chainStarted;

        BigDecimal previousAfter() {
            if (chainStarted) return chainAfter;
            return exists ? weight : BigDecimal.ZERO;
        }

        void adjustment(BigDecimal before, BigDecimal after, String kind) {
            assertThat(sameKg(before, previousAfter()))
                    .as("%s before %s must continue previous after %s", kind, before, previousAfter()).isTrue();
            assertThat(after == null || after.signum() >= 0).as("%s after %s", kind, after).isTrue();
            chainAfter = after;
            chainStarted = true;
        }

        void movement(boolean in, BigDecimal kg, BigDecimal after, boolean exact) {
            BigDecimal before = previousAfter();
            if (!exact && kg != null && before != null && after != null) {
                BigDecimal expected = in ? before.add(kg) : before.subtract(kg);
                assertThat(after).as("movement %s from %s by %s", after, before, kg).isEqualByComparingTo(expected);
            }
            assertThat(after == null || after.signum() >= 0).as("movement after %s", after).isTrue();
            chainAfter = after;
            chainStarted = true;
        }

        void assertConsistent() {
            assertThat(sameKg(chainAfter, weight)).as("last ledger after %s equals balance %s", chainAfter, weight)
                    .isTrue();
            boolean valid = weight == null
                    || (qty.signum() == 0 && weight.signum() == 0)
                    || (qty.signum() > 0 && weight.signum() > 0);
            assertThat(valid).as("balance qty %s weight %s", qty, weight).isTrue();
            if (weight == null || qty.signum() == 0) assertThat(estimated).isFalse();
        }
    }

    private static final class Book {
        final Map<UUID, Dim> dims = new LinkedHashMap<>();
        final List<Posted> movements = new ArrayList<>();
        BigDecimal goodsFactor;
        BigDecimal lineFactor;
        UnitWeightLookup.UnitWeightRef apw;

        Dim dim(UUID warehouse) {
            return dims.computeIfAbsent(warehouse, ignored -> new Dim());
        }

        void seed(UUID warehouse, String qty, String weight) {
            Dim dim = dim(warehouse);
            dim.qty = new BigDecimal(qty);
            dim.weight = weight == null ? null : new BigDecimal(weight);
            dim.exists = true;
        }

        StockWeightResolver.WeightResolution post(StockService.MovementRequest request) {
            Dim dim = dim(request.warehouseId());
            var context = new StockWeightResolver.WeightContext(dim.qty, dim.weight, dim.estimated, dim.exists,
                    goodsFactor, lineFactor, pool(request), counterpart(request), () -> apw);
            var resolution = StockWeightResolver.resolve(context, request);
            assertThat(resolution.weightKg() == null).isEqualTo(resolution.source() == null);
            boolean in = request.direction() == StockService.DIR_IN;
            resolution.before().forEach(a -> dim.adjustment(a.before(), a.after(), a.kind()));
            // 负数量起算没有调整行, 流水行直接给出新重量; 其余情况「前 +/- 本笔 = 后」。
            boolean reanchored = dim.qty.signum() < 0;
            dim.movement(in, resolution.weightKg(), resolution.balanceWeightAfter(), goodsFactor != null || reanchored);
            dim.qty = in ? dim.qty.add(request.qty()) : dim.qty.subtract(request.qty());
            dim.weight = resolution.balanceWeightAfter();
            dim.estimated = resolution.estimatedAfter();
            dim.exists = true;
            dim.assertConsistent();
            movements.add(new Posted(request, resolution.weightKg(), resolution.source()));
            return resolution;
        }

        Count count(UUID warehouse, String targetKg) {
            Dim dim = dim(warehouse);
            BigDecimal before = dim.weight;
            BigDecimal after = WeightMath.round4(new BigDecimal(targetKg));
            dim.adjustment(before, after, "COUNT");
            dim.weight = after;
            dim.estimated = false;
            dim.assertConsistent();
            return new Count(before, after);
        }

        void reverseCount(UUID warehouse, Count count) {
            Dim dim = dim(warehouse);
            var reversal = StockWeightResolver.reverseCount(dim.qty, dim.weight, dim.estimated,
                    count.before(), count.after());
            dim.adjustment(dim.weight, reversal.weightAfter(), "REVERSAL");
            dim.weight = reversal.weightAfter();
            dim.estimated = reversal.estimatedAfter();
            dim.assertConsistent();
        }

        private StockWeightResolver.Pool pool(StockService.MovementRequest request) {
            BigDecimal inQty = BigDecimal.ZERO;
            BigDecimal outQty = BigDecimal.ZERO;
            BigDecimal inKg = BigDecimal.ZERO;
            BigDecimal outKg = BigDecimal.ZERO;
            boolean allKnown = true;
            boolean any = false;
            WeightSource weakest = null;
            for (Posted posted : movements) {
                var prior = posted.request();
                if (!Objects.equals(prior.sourceDocType(), request.sourceDocType())
                        || !Objects.equals(prior.sourceDocId(), request.sourceDocId())
                        || !Objects.equals(prior.sourceItemId(), request.sourceItemId())
                        || prior.movementType() != request.movementType()
                        || !prior.warehouseId().equals(request.warehouseId())
                        || !Objects.equals(prior.colorId(), request.colorId())) continue;
                any = true;
                boolean in = prior.direction() == StockService.DIR_IN;
                if (in) inQty = inQty.add(prior.qty());
                else outQty = outQty.add(prior.qty());
                if (posted.kg() == null) {
                    allKnown = false;
                    continue;
                }
                if (in) inKg = inKg.add(posted.kg());
                else outKg = outKg.add(posted.kg());
                weakest = WeightSource.weakest(weakest, posted.source());
            }
            return any ? new StockWeightResolver.Pool(inQty, outQty, inKg, outKg, allKnown, weakest) : null;
        }

        private StockWeightResolver.Counterpart counterpart(StockService.MovementRequest request) {
            if (request.movementType() != TRANSFER_IN || request.direction() != StockService.DIR_IN) return null;
            StockWeightResolver.Counterpart result = null;
            for (Posted posted : movements) {
                var prior = posted.request();
                if (prior.movementType() == TRANSFER_OUT && prior.direction() == StockService.DIR_OUT
                        && Objects.equals(prior.sourceDocId(), request.sourceDocId())
                        && Objects.equals(prior.sourceItemId(), request.sourceItemId())) {
                    result = new StockWeightResolver.Counterpart(posted.kg(), posted.source());
                }
            }
            return result;
        }
    }

    // ===== 工具 =====

    private static StockService.MovementRequest request(short type, short direction, UUID warehouse, String qty,
                                                        CapturedWeight weight) {
        return request(type, direction, warehouse, qty, weight, UUID.randomUUID(), UUID.randomUUID());
    }

    private static StockService.MovementRequest request(short type, short direction, UUID warehouse, String qty,
                                                        CapturedWeight weight, UUID doc, UUID item) {
        return new StockService.MovementRequest(OffsetDateTime.now(), type, "STOCK_DOC", doc, item, GOODS, null,
                warehouse, direction, new BigDecimal(qty), UUID.randomUUID(), BigDecimal.ONE, null, null, weight);
    }

    private static boolean sameKg(BigDecimal a, BigDecimal b) {
        return WeightMath.sameKg(a, b);
    }

    private static void assertKg(BigDecimal actual, String expected) {
        assertThat(actual).isNotNull();
        assertThat(actual).isEqualByComparingTo(expected);
    }
}
