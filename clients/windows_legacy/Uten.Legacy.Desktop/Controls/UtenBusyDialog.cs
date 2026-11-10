using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;

namespace Uten.Legacy.Desktop.Controls
{
    /// <summary>One owned waiting dialog for an actual asynchronous operation, including nested reads.</summary>
    /// <remarks>
    /// 2026-11-09 与 Flutter「统一进度弹窗」同步（ADR 见 docs/02-组件库/通用进度弹窗.md）：
    /// 新增确定进度模式 <see cref="ShowProgress"/>——已知总量时显示百分比进度条与
    /// 「已办 / 总数」详情行；总量未知仍用 <see cref="Show"/> 的扫动条并只汇报详情
    /// （<see cref="Stage"/>），不伪造百分比。样式（主色/间距/描边）全部走 Uten.*
    /// 资源引用，与全项目唯一样式来源保持一致；已提交的业务请求没有真正取消，
    /// 与 Flutter 端一致不提供误导性的「取消」（读取/下载类由调用方传入 cancel）。
    /// </remarks>
    public sealed class UtenBusyDialog : IDisposable
    {
        private sealed class Entry
        {
            internal Window Owner;
            internal BusyWindow Window;
            internal bool Enabled;
            internal int Leases;
        }
        private sealed class BusyWindow : UtenDialogWindow
        {
            private readonly Action cancel;
            private readonly ProgressBar bar;
            private readonly TextBlock detail;
            internal bool Finished, ClosedAlready;
            internal BusyWindow(Window owner, string title, Action cancel, bool determinate) : base(owner, title, 360)
            {
                this.cancel = cancel;
                bar = new ProgressBar { IsIndeterminate = !determinate, Minimum = 0, Maximum = 1000 };
                bar.SetResourceReference(HeightProperty, "Uten.Space.S12");
                bar.SetResourceReference(ForegroundProperty, "Uten.PrimaryBrush");
                Body.Children.Add(bar);
                detail = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, Space("S8"), 0, 0), Visibility = Visibility.Collapsed };
                detail.SetResourceReference(TextBlock.ForegroundProperty, "Uten.Muted");
                Body.Children.Add(detail);
                CloseButton.IsEnabled = cancel != null;
                if (cancel != null) ActionButton("取消", cancel);
                Closed += (sender, args) => ClosedAlready = true;
            }
            internal void Report(double? fraction, string message)
            {
                if (fraction.HasValue && !bar.IsIndeterminate)
                {
                    var clamped = fraction.Value;
                    if (clamped < 0) clamped = 0; else if (clamped > 1) clamped = 1;
                    bar.Value = clamped * 1000;
                }
                if (message != null)
                {
                    detail.Text = message;
                    detail.Visibility = string.IsNullOrEmpty(message) ? Visibility.Collapsed : Visibility.Visible;
                }
            }
            protected override void OnClosing(CancelEventArgs args)
            {
                if (!Finished && Owner?.IsVisible == true)
                {
                    args.Cancel = true;
                    cancel?.Invoke();
                }
                base.OnClosing(args);
            }
        }
        private static readonly Dictionary<Window, Entry> active = new Dictionary<Window, Entry>();
        private Entry entry;
        private UtenBusyDialog(Entry value) { entry = value; }
        public static UtenBusyDialog Show(Window owner, string title, Action cancel = null)
        {
            return ShowShared(owner, title, cancel, false);
        }
        /// <summary>确定进度模式：进度条按汇报比例填充并显示百分比；总量未知时改用 <see cref="Show"/>。</summary>
        public static UtenBusyDialog ShowProgress(Window owner, string title, Action cancel = null)
        {
            return ShowShared(owner, title, cancel, true);
        }
        private static UtenBusyDialog ShowShared(Window owner, string title, Action cancel, bool determinate)
        {
            if (owner == null) throw new ArgumentNullException(nameof(owner));
            owner.Dispatcher.VerifyAccess();
            if (!owner.IsVisible) return new UtenBusyDialog(null);
            Entry value;
            if (!active.TryGetValue(owner, out value))
            {
                value = new Entry { Owner = owner, Enabled = owner.IsEnabled, Window = new BusyWindow(owner, title, cancel, determinate) };
                active.Add(owner, value);
                try { owner.IsEnabled = false; value.Window.Show(); }
                catch { active.Remove(owner); owner.IsEnabled = value.Enabled; throw; }
            }
            value.Leases++;
            return new UtenBusyDialog(value);
        }
        /// <summary>汇报计数型进度：done/total 显示百分比与「done / total」详情；total ≤ 0 时只更新详情。</summary>
        public void Report(long done, long total)
        {
            var window = entry == null ? null : entry.Window;
            if (window == null) return;
            if (total <= 0) { Stage(done.ToString()); return; }
            var safe = done < 0 ? 0 : (done > total ? total : done);
            window.Report(safe / (double)total, safe + " / " + total);
        }
        /// <summary>只更新详情行（阶段句/已收字节等），不动进度条；空串收起详情行。</summary>
        public void Stage(string message)
        {
            var window = entry == null ? null : entry.Window;
            if (window != null) window.Report(null, message ?? string.Empty);
        }
        public void Dispose()
        {
            var value = entry; entry = null;
            if (value == null || --value.Leases != 0) return;
            active.Remove(value.Owner);
            value.Window.Finished = true;
            try { if (!value.Window.ClosedAlready) value.Window.Close(); }
            finally { value.Owner.IsEnabled = value.Enabled; }
        }
    }
}
