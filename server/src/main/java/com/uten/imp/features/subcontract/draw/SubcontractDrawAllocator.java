package com.uten.imp.features.subcontract.draw;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;

/**
 * ADR-143 §二.16 / §三 同一次批量领料的联合分配(纯计算, 不读库不加锁)。
 *
 * <p>唯一一对正反函数(与数据库 {@code fn_subcontract_draw_f} / {@code TRUNC(x/b,4)} 逐位一致):
 * {@code f(S) = CEIL(S × b, 4)}(套数 → 物料量), {@code sets(x) = TRUNC(x / b, 4)}(物料量 → 套数);
 * 在 0.0001 网格上 {@code f(S) ≤ x ⟺ S ≤ sets(x)}。所有套数再取 {@code LEAST(Qm, …)}, Qm = 我方供料套数
 * (订货量扣掉财务批准的委外商自带料, 不低于已领套数; 没有自带料时就是订货量, ADR-143 §三.4a,
 * 与数据库 {@code fn_subcontract_material_qty} 同一个数, 由调用方读出后传入)。
 *
 * <p>任务按调用方给的顺序(交期、订货单号、行号)依次分配: 每个任务先算本批可领
 * {@code LEAST(Qm, MIN_i sets(covered_i + avail_i)) − LEAST(Qm, MIN_i sets(covered_i))},
 * 其中公共库存扣掉前面任务本批已经分走的; 本次数量 S 之后每种物料要领
 * {@code MAX(0, f_i(complete + S) − covered_i)}——领先的物料不多发, 落后的先补齐。
 * 逐仓切片分两轮, 跨仓先专属: 第一轮在所有有本任务专属批次的仓里先拿专属批次(专属多的仓在前),
 * 第二轮才动公共库存(该仓剩余公共可用多的在前, 同量按仓编码)。同一仓两轮拿到的合成一段,
 * 每个(任务, 计划行, 仓)只出一段; 占用时 reserveDraft 也是先接收该仓专属批次再占公共, 口径一致。
 */
final class SubcontractDrawAllocator {

    private static final int SCALE = 4;

    private SubcontractDrawAllocator() {
    }

    /** 某仓里本计划行可动用的量(基本单位): 本订货明细专属批次 + 该仓公共可用(全体共享)。 */
    record Stock(UUID warehouseId, String warehouseCode, String warehouseName,
                 BigDecimal exactQty, BigDecimal publicQty) {
    }

    /** 一条冻结计划行: covered = 已发净量 + 待仓库发。 */
    record Line(UUID planItemId, UUID goodsId, UUID colorId, BigDecimal perUnitQty,
                BigDecimal plannedQty, BigDecimal coveredQty, List<Stock> stocks) {
    }

    /** 一个委外任务(订货明细); materialShareQty = Qm(套数封顶); requestedQty 为 null 时取本批可领。 */
    record Task(UUID orderItemId, UUID orderId, BigDecimal materialShareQty,
                BigDecimal requestedQty, List<Line> lines) {
    }

    /** 一个仓里本次要领的一段(基本单位), warehouseAvailableQty 为分配前该仓本行可动用量。 */
    record Slice(UUID orderItemId, UUID orderId, UUID planItemId, UUID goodsId, UUID colorId,
                 UUID warehouseId, String warehouseCode, String warehouseName,
                 BigDecimal qty, BigDecimal warehouseAvailableQty) {
    }

    record TaskResult(UUID orderItemId, BigDecimal completeQty, BigDecimal batchDrawableQty,
                      BigDecimal qty, boolean exceeded) {
    }

    record Result(List<TaskResult> tasks, List<Slice> slices) {
        Result {
            tasks = List.copyOf(tasks);
            slices = List.copyOf(slices);
        }

        boolean anyExceeded() {
            return tasks.stream().anyMatch(TaskResult::exceeded);
        }
    }

    /** 物料量 → 套数: TRUNC(x / b, 4)。 */
    static BigDecimal sets(BigDecimal materialQty, BigDecimal perUnitQty) {
        return materialQty.divide(perUnitQty, SCALE, RoundingMode.DOWN);
    }

    /** 套数 → 物料量: CEIL(S × b, 4)。 */
    static BigDecimal materialQty(BigDecimal sets, BigDecimal perUnitQty) {
        return sets.multiply(perUnitQty).setScale(SCALE, RoundingMode.CEILING);
    }

    /**
     * 已覆盖套数: LEAST(Qm, MIN_i sets(covered_i))。没有计划行时为 0, 与 fn_subcontract_draw_summary
     * 同口径(已批准明细一定有计划行; 万一没有不放行)。
     */
    static BigDecimal completeQty(BigDecimal materialShareQty, List<Line> lines) {
        if (lines.isEmpty()) return BigDecimal.ZERO;
        BigDecimal complete = materialShareQty;
        for (Line line : lines) {
            complete = complete.min(sets(line.coveredQty(), line.perUnitQty()));
        }
        return complete.max(BigDecimal.ZERO);
    }

    static Result allocate(List<Task> orderedTasks) {
        Map<PublicKey, BigDecimal> publicUsed = new HashMap<>();
        List<TaskResult> results = new ArrayList<>();
        List<Slice> slices = new ArrayList<>();
        for (Task task : orderedTasks) {
            BigDecimal materialShareQty = task.materialShareQty();
            BigDecimal complete = completeQty(materialShareQty, task.lines());
            BigDecimal reach = materialShareQty;
            for (Line line : task.lines()) {
                BigDecimal avail = BigDecimal.ZERO;
                for (Stock stock : line.stocks()) {
                    avail = avail.add(positive(stock.exactQty()))
                            .add(publicLeft(publicUsed, line, stock));
                }
                reach = reach.min(sets(line.coveredQty().add(avail), line.perUnitQty()));
            }
            BigDecimal batch = task.lines().isEmpty()
                    ? BigDecimal.ZERO
                    : reach.subtract(complete).max(BigDecimal.ZERO);
            BigDecimal qty = task.requestedQty() == null ? batch : task.requestedQty();
            boolean exceeded = qty.compareTo(batch) > 0;
            results.add(new TaskResult(task.orderItemId(), complete, batch, qty, exceeded));
            if (exceeded || qty.signum() <= 0) {
                continue;
            }
            BigDecimal target = complete.add(qty);
            for (Line line : task.lines()) {
                BigDecimal need = materialQty(target, line.perUnitQty())
                        .subtract(line.coveredQty()).max(BigDecimal.ZERO);
                if (need.signum() == 0) {
                    continue;
                }
                Map<UUID, BigDecimal> takes = new LinkedHashMap<>();
                Map<UUID, Stock> takenFrom = new HashMap<>();
                // 第一轮: 本任务专属批次(跨仓), 不动公共库存。
                List<Stock> exactFirst = new ArrayList<>(line.stocks());
                exactFirst.sort(Comparator
                        .comparing((Stock stock) -> positive(stock.exactQty())).reversed()
                        .thenComparing(stock -> Objects.toString(stock.warehouseCode(), ""))
                        .thenComparing(stock -> stock.warehouseId().toString()));
                for (Stock stock : exactFirst) {
                    if (need.signum() == 0) {
                        break;
                    }
                    BigDecimal exactTake = need.min(positive(stock.exactQty()));
                    if (exactTake.signum() <= 0) {
                        continue;
                    }
                    takes.merge(stock.warehouseId(), exactTake, BigDecimal::add);
                    takenFrom.putIfAbsent(stock.warehouseId(), stock);
                    need = need.subtract(exactTake);
                }
                // 第二轮: 专属不够的部分才占公共库存(扣掉本批前面任务已分走的)。
                List<Stock> publicNext = new ArrayList<>(line.stocks());
                publicNext.sort(Comparator
                        .comparing((Stock stock) -> publicLeft(publicUsed, line, stock)).reversed()
                        .thenComparing(stock -> Objects.toString(stock.warehouseCode(), ""))
                        .thenComparing(stock -> stock.warehouseId().toString()));
                for (Stock stock : publicNext) {
                    if (need.signum() == 0) {
                        break;
                    }
                    BigDecimal publicTake = need.min(publicLeft(publicUsed, line, stock));
                    if (publicTake.signum() <= 0) {
                        continue;
                    }
                    publicUsed.merge(new PublicKey(stock.warehouseId(), line.goodsId(), line.colorId()),
                            publicTake, BigDecimal::add);
                    takes.merge(stock.warehouseId(), publicTake, BigDecimal::add);
                    takenFrom.putIfAbsent(stock.warehouseId(), stock);
                    need = need.subtract(publicTake);
                }
                for (Map.Entry<UUID, BigDecimal> take : takes.entrySet()) {
                    Stock stock = takenFrom.get(take.getKey());
                    slices.add(new Slice(task.orderItemId(), task.orderId(), line.planItemId(),
                            line.goodsId(), line.colorId(), stock.warehouseId(), stock.warehouseCode(),
                            stock.warehouseName(), take.getValue(),
                            positive(stock.exactQty()).add(positive(stock.publicQty()))));
                }
                if (need.signum() > 0) {
                    // f(complete + S) ≤ covered + avail 由 S ≤ 本批可领保证; 走到这里说明库存事实在
                    // 计算过程中自相矛盾(同一物料的公共可用在不同计划行上读到了不同值)。
                    throw new IllegalStateException("draw allocation could not cover the requested material");
                }
            }
        }
        return new Result(results, slices);
    }

    private static BigDecimal publicLeft(Map<PublicKey, BigDecimal> used, Line line, Stock stock) {
        BigDecimal taken = used.getOrDefault(
                new PublicKey(stock.warehouseId(), line.goodsId(), line.colorId()), BigDecimal.ZERO);
        return positive(stock.publicQty()).subtract(taken).max(BigDecimal.ZERO);
    }

    private static BigDecimal positive(BigDecimal value) {
        return value == null ? BigDecimal.ZERO : value.max(BigDecimal.ZERO);
    }

    private record PublicKey(UUID warehouseId, UUID goodsId, UUID colorId) {
    }
}
