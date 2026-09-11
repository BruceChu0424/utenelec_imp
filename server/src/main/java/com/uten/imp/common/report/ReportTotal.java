package com.uten.imp.common.report;

import java.util.List;

/**
 * 报表表格下方「合计条」的一项（全报表服务共用，随 ReportTableResponse 下发）。
 *
 * <p><b>为什么合计必须由服务端算</b>：报表表格一律服务端分页（一页 50 行），
 * 前端对「当前页」求和会得出一个看着像总计、其实只覆盖一页的数——比不显示合计更糟。
 * 本项的值由 {@link ReportTotalsCalculator} 用与列表<b>完全相同</b>的过滤条件
 * （含对象级授权谓词）在整个结果集上聚合出来，与翻到第几页无关。
 *
 * <p><b>为什么是 groups 而不是单个数</b>：数量不得跨单位相加、金额不得跨币种相加。
 * 服务端按分组列（单位名/币种名）分好组下发，前端只负责把各组拼成「12 个 · 3 箱」，
 * 不做任何加法——跨单位相加在结构上就不可能发生。
 *
 * @param key      列 key（= 前端列键，便于定位）
 * @param label    合计项标题（如「合计数量」「合计金额」）
 * @param type     number / money —— 前端据此选格式化口径
 * @param groupKey 分组列 key；null = 本报表没有分组维度，{@link #groups} 只有一组
 * @param groups   分组合计。<b>groupKey 非 null 时</b> {@code unit} 为 null 的那组是
 *                 「该行单位/币种没维护」，前端渲染成「单位未维护」而不是无后缀数字；
 *                 <b>groupKey 为 null 时</b>只有一组且 {@code unit} 恒为 null，渲染成纯数值。
 */
public record ReportTotal(String key, String label, String type, String groupKey,
                          List<ReportTotalGroup> groups) {}
