# 独立滚动坐标回归复核

旧产品为14e7be5e7（完整SHA见comparison），新产品178e5a295091b4e817676e6fe0e224b2765fd5ae。两份独立工作树、相同字节探针、生产无改动；不以结构换型当失败。

## 确证行为

真实ListView100行、外部outer控制器、96像素头。以真实滚轮及原350ms hold建立inner950；跨宽1000→320或高900→390后两版都outer0/inner950；小轮24两版都outer24/inner950；下一格1000收头到边界：

| 输入 | 旧14e | 新178 |
|---|---|---|
| wide→compact | inner950保持/outer96 | inner归0/outer96 |
| tall→short | inner950保持/outer66 | inner归0/outer66 |

正确断言probe `scroll_offset_retention_regression_test.dart`：旧2/2通过退出0，新0通过2失败退出1。新增无条件inner.jumpTo(min)把原compact保存坐标清掉。96/24/48及gate/hold原阈值均未修改。

双向facts probe只收事实、不能把其退出0当验收：compact→wide、short→tall时旧Nested原来就于收头边界归inner0，新旧一致。不能全局删reset改变此合同。

Hierarchy相邻stableBodyViewport=true事实：宽变两版outer可滚量0且保位；tall→short旧inner1000保持、新归0；反向回tall一致。

## 外部controller实际用法

`goods_cost_actual_panel.dart:_revealHeader`会对传入组件的_outer.animateTo(0)。同compact尺寸不换结构，实际inner950/outer96→外部animateTo0→小24→边界轮1000，旧保950、新归0。正确独立单例旧1/1绿、新0/1红；见animate-baseline/current-7原件。因此不能只为刚跨mode的一次动作跳过reset。

## 限定源码复核

MTDT相对14e仅3行可执行逻辑改为最近outerControllerOf优先、原Nested兜底；mounted/页scope/generation/pending-end等栅栏和先归零body再归零outer步骤保留，行身份/width cursor/layout cache/fresh closures没有被这3行覆盖。

rail只新增semantic boundary/explicit child nodes；原canPaint的routeCurrent、ticker、modal、candidate门及hitTest/visitChildrenForSemantics门仍在。未发现这几行弱化资格的证据，不把源码检查当网页/读屏设备通过。

## 不计作回归的准备失败

第1轮直接jumpTo未把旧wide/Nested真滚非零；第2/3轮前两格还在header88→96稳定期。其准备断言失败及原代码都保留，不能算产品回归。第4轮有界真实轮/原351ms停顿驱动到实测inner>100，两产品都得到950；第5原正确断言才用于判定。未改超时或降低真实offset要求。首次归档glob碰到old14e不存在的其他产品test而停止，原件未改，改为明确四个helper名完成归档。

Root负责owned最小修；新候选须原样重跑compact两例、外部animate、stable高度事实和反向旧Nested0控制。本组为Flutter行为/源码复核，不冒称Root真实Web/目标设备通过。
