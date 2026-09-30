// Web 全局拖放守卫：浏览器默认会把「拖文件到页面」当成打开该文件（整页导航走，
// 应用被顶掉）。在 document 上 preventDefault 掉默认行为——落在接收区（UtenDropTarget）
// 的文件照常触发组件回调，落在其它区域的拖放则被吞掉不再导航。
// 桌面/移动端无此默认行为，io 实现为空。
import 'browser_drop_guard_web.dart'
    if (dart.library.io) 'browser_drop_guard_io.dart'
    as impl;

void installBrowserDropGuard() => impl.install();
