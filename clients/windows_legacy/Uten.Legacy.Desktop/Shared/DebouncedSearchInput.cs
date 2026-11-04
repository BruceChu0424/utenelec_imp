using System;
using System.Threading.Tasks;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;

namespace Uten.Legacy.Desktop.Shared
{
    /// <summary>One input policy for native searches; the owning view still fences read results.</summary>
    public sealed class DebouncedSearchInput
    {
        private readonly DispatcherTimer delay = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        private readonly Action invalidate;
        private readonly Func<Task> read;
        private readonly Func<bool> available;
        private bool composing;
        private long generation, runningGeneration = -1;
        private ReadFlight activeRead;

        private sealed class ReadFlight
        {
            public object Key;
            public long Generation;
            public Func<bool> IsCurrent;
            public readonly TaskCompletionSource<bool> Completion = new TaskCompletionSource<bool>();
        }

        public DebouncedSearchInput(TextBox input, Action invalidate, Func<Task> read, Func<bool> available)
        {
            this.invalidate = invalidate ?? throw new ArgumentNullException(nameof(invalidate));
            this.read = read ?? throw new ArgumentNullException(nameof(read));
            this.available = available ?? throw new ArgumentNullException(nameof(available));
            if (input == null) throw new ArgumentNullException(nameof(input));
            TextCompositionManager.AddPreviewTextInputStartHandler(input, (sender, args) => { composing = true; delay.Stop(); });
            TextCompositionManager.AddPreviewTextInputHandler(input, (sender, args) =>
            {
                if (!composing) return;
                composing = false;
                if (available()) { delay.Stop(); delay.Start(); }
            });
            input.TextChanged += (sender, args) =>
            {
                delay.Stop();
                if (!available()) return;
                generation++; this.invalidate();
                if (!composing) delay.Start();
            };
            input.KeyDown += async (sender, args) =>
            {
                if (args.Key != Key.Enter || composing) return;
                args.Handled = true;
                await ReadAsync();
            };
            delay.Tick += async (sender, args) => await ReadAsync();
        }

        public void Stop() { delay.Stop(); composing = false; generation++; }

        /// <summary>All leaf read triggers share their real query/page/scope identity.
        /// Cancel only the pending timer: an explicit filter/category read must
        /// not leave the same text scheduled, or retire a valid joined request.</summary>
        public Task RunReadAsync(object queryIdentity, Func<bool> isCurrent, Func<Task> action)
        {
            delay.Stop();
            if (composing || !available()) return Task.CompletedTask;
            var previous = activeRead;
            if (previous != null && previous.Generation == generation && Object.Equals(previous.Key, queryIdentity)
                && !previous.Completion.Task.IsCompleted && previous.IsCurrent()) return previous.Completion.Task;
            var flight = new ReadFlight { Key = queryIdentity, Generation = generation, IsCurrent = isCurrent };
            activeRead = flight;
            _ = CompleteReadAsync(flight, action);
            return flight.Completion.Task;
        }

        private async Task CompleteReadAsync(ReadFlight flight, Func<Task> action)
        {
            try { await action(); flight.Completion.TrySetResult(true); }
            catch (Exception error) { flight.Completion.TrySetException(error); }
            finally { if (Object.ReferenceEquals(activeRead, flight)) activeRead = null; }
        }

        private async Task ReadAsync()
        {
            delay.Stop();
            if (composing || !available() || runningGeneration == generation) return;
            long owner = generation;
            runningGeneration = owner;
            try { await read(); }
            finally { if (runningGeneration == owner) runningGeneration = -1; }
        }
    }
}
