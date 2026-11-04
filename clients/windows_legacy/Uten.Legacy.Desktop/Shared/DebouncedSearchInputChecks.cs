using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;

namespace Uten.Legacy.Desktop.Shared
{
    public static class DebouncedSearchInputChecks
    {
        public static int Run()
        {
            int checks = 0, reads = 0, invalidations = 0;
            Action<bool, string> check = (condition, message) => { if (!condition) throw new InvalidOperationException(message); checks++; };
            var input = new TextBox();
            var window = new Window { Content = input, Width = 300, Height = 100, Opacity = 0, ShowInTaskbar = false, ShowActivated = false };
            var pending = new TaskCompletionSource<bool>();
            var binding = new DebouncedSearchInput(input, () => invalidations++, () => { reads++; return pending.Task; }, () => input.IsLoaded);
            try
            {
                window.Show();
                var composition = new TextComposition(InputManager.Current, input, "");
                input.RaiseEvent(new TextCompositionEventArgs(Keyboard.PrimaryDevice, composition) { RoutedEvent = TextCompositionManager.PreviewTextInputStartEvent });
                input.Text = "zhong";
                Pump(400);
                check(invalidations == 1 && reads == 0, "IME updates invalidate old results immediately without querying unfinished text.");
                input.Text = "中";
                input.RaiseEvent(new TextCompositionEventArgs(Keyboard.PrimaryDevice, composition) { RoutedEvent = TextCompositionManager.PreviewTextInputEvent });
                Pump(400);
                check(reads == 1, "Committed IME text is queried once after the shared debounce.");
                Action enter = () => input.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(input), 0, Key.Enter) { RoutedEvent = Keyboard.KeyDownEvent });
                enter(); enter();
                check(reads == 1, "Repeated Enter does not cancel and restart the same in-flight search.");
                input.Text = "中文";
                Pump(400);
                check(reads == 2 && invalidations == 3, "A new query can supersede a running query; the view keeps its existing response generation fence.");
                pending.SetResult(true); Pump(25);
                input.Text = "next"; binding.Stop(); Pump(400);
                check(reads == 2, "Retiring or leaving the view prevents delayed search dispatch.");
            }
            finally { binding.Stop(); pending.TrySetResult(true); window.Close(); }
            return checks;
        }

        private static void Pump(int milliseconds)
        {
            var frame = new DispatcherFrame();
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(milliseconds) };
            timer.Tick += (sender, args) => { timer.Stop(); frame.Continue = false; };
            timer.Start(); Dispatcher.PushFrame(frame);
        }
    }
}
