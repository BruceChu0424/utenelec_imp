using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Uten.Legacy.Desktop.Controls;

namespace Uten.Legacy.Desktop.Shared
{
    public static class BusyDialogProgressChecks
    {
        public static int Run()
        {
            if (Application.Current == null)
            {
                var app = new App(); app.InitializeComponent();
                app.ShutdownMode = ShutdownMode.OnExplicitShutdown;
            }
            int count = 0;
            Action<bool, string> check = (condition, label) =>
            {
                if (!condition) throw new InvalidOperationException("Busy dialog progress: " + label);
                count++;
            };
            var owner = new Window { Width = 480, Height = 240, ShowInTaskbar = false,
                Content = new TextBox { Text = "retained draft" } };
            owner.Show(); Pump(owner);
            try
            {
                using (var progress = UtenBusyDialog.ShowProgress(owner, "synthetic progress"))
                {
                    Pump(owner);
                    var window = owner.OwnedWindows.Cast<Window>().Single();
                    var bar = Find<ProgressBar>(window);
                    check(bar != null && !bar.IsIndeterminate, "ShowProgress starts determinate");
                    progress.Report(1, 4); Pump(window);
                    check(!bar.IsIndeterminate && bar.Value == 250, "known count displays its real fraction");
                    progress.Stage("waiting for next total"); Pump(window);
                    check(bar.IsIndeterminate && bar.Value == 0, "Stage withdraws the old percentage and switches to unknown");
                    check(Find<TextBlock>(window, text => text.Text == "waiting for next total") != null,
                        "unknown stage retains its current message");
                    progress.Report(3, 4); Pump(window);
                    check(!bar.IsIndeterminate && bar.Value == 750, "Report restores determinate progress after Stage");
                    progress.Report(5, 0); Pump(window);
                    check(bar.IsIndeterminate && bar.Value == 0, "unknown total retires the prior fraction");
                    progress.Report(-2, 4); Pump(window);
                    check(!bar.IsIndeterminate && bar.Value == 0, "negative done clamps without inventing work");
                    progress.Report(9, 4); Pump(window);
                    check(!bar.IsIndeterminate && bar.Value == 1000, "done above total clamps to completion");
                    using (var nested = UtenBusyDialog.Show(owner, "nested read"))
                    {
                        nested.Stage("reading"); Pump(window);
                        check(owner.OwnedWindows.Count == 1 && !owner.IsEnabled && bar.IsIndeterminate,
                            "nested reads reuse the single wait dialog and can withdraw a stale fraction");
                    }
                    check(owner.OwnedWindows.Count == 1 && !owner.IsEnabled,
                        "disposing the nested lease does not dismiss the outer operation");
                    for (int index = 0; index < 25; index++)
                    {
                        progress.Stage("batch " + index); Pump(window);
                        check(bar.IsIndeterminate && bar.Value == 0, "repeated stages never publish the old percentage");
                        progress.Report(index, 25); Pump(window);
                        check(!bar.IsIndeterminate && bar.Value == index * 40,
                            "repeated known counts restore the exact current progress");
                    }
                }
                Pump(owner);
                check(owner.IsEnabled && owner.OwnedWindows.Count == 0,
                    "finishing restores the owner and removes the only dialog");
                using (var wait = UtenBusyDialog.Show(owner, "initially unknown"))
                {
                    Pump(owner);
                    var window = owner.OwnedWindows.Cast<Window>().Single();
                    var bar = Find<ProgressBar>(window);
                    check(bar.IsIndeterminate, "Show starts unknown");
                    wait.Report(1, 2); Pump(window);
                    check(!bar.IsIndeterminate && bar.Value == 500,
                        "Show followed by Report becomes determinate when a real total arrives");
                    wait.Stage(null); Pump(window);
                    check(bar.IsIndeterminate && Find<TextBlock>(window, text => text.Text == "1 / 2") == null,
                        "null Stage removes stale count text and percentage");
                }
                Pump(owner);
                check(owner.IsEnabled && ((TextBox)owner.Content).Text == "retained draft",
                    "mode changes do not alter the owner's input or enabled state");
            }
            finally { owner.Close(); Pump(owner); }
            return count;
        }

        private static T Find<T>(DependencyObject root, Func<T, bool> predicate = null) where T : DependencyObject
        {
            var found = root as T;
            if (found != null && (predicate == null || predicate(found))) return found;
            for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            {
                found = Find(VisualTreeHelper.GetChild(root, index), predicate);
                if (found != null) return found;
            }
            return null;
        }

        private static void Pump(Window window)
        {
            window.UpdateLayout();
            var frame = new DispatcherFrame();
            Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle,
                new Action(() => frame.Continue = false));
            Dispatcher.PushFrame(frame);
        }
    }
}
