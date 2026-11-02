using System;
using System.Diagnostics;
using System.Threading;
using System.Windows.Threading;
using Uten.Legacy.Core;

namespace Uten.Legacy.Desktop.Shared
{
    internal sealed class DiagnosticWatchdog : IDisposable
    {
        private readonly Dispatcher dispatcher;
        private readonly Timer timer;
        private long acknowledged = Stopwatch.GetTimestamp();
        private int pending, reported;
        internal DiagnosticWatchdog(Dispatcher dispatcher)
        {
            this.dispatcher = dispatcher;
            timer = new Timer(Tick, null, 1000, 1000);
        }
        private void Tick(object ignored)
        {
            long delay = (Stopwatch.GetTimestamp() - Interlocked.Read(ref acknowledged)) * 1000 / Stopwatch.Frequency;
            if (Volatile.Read(ref pending) != 0 && delay > 5000 && Interlocked.Exchange(ref reported, 1) == 0)
                DiagnosticsLog.Record("window.unresponsive", "heartbeat_timeout", elapsed: delay);
            if (dispatcher.HasShutdownStarted || Interlocked.Exchange(ref pending, 1) != 0) return;
            try
            {
                dispatcher.BeginInvoke(new Action(() =>
                {
                    Interlocked.Exchange(ref acknowledged, Stopwatch.GetTimestamp());
                    Interlocked.Exchange(ref pending, 0);
                    if (Interlocked.Exchange(ref reported, 0) != 0) DiagnosticsLog.Record("window.recovered");
                }), DispatcherPriority.Background);
            }
            catch (InvalidOperationException) { }
        }
        public void Dispose() { timer.Dispose(); }
    }
}
