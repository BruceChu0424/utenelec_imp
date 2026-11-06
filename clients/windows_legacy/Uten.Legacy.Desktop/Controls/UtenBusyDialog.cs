using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;

namespace Uten.Legacy.Desktop.Controls
{
    /// <summary>One owned waiting dialog for an actual asynchronous operation, including nested reads.</summary>
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
            internal bool Finished, ClosedAlready;
            internal BusyWindow(Window owner, string title, Action cancel) : base(owner, title, 360)
            {
                this.cancel = cancel;
                Body.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 4 });
                CloseButton.IsEnabled = cancel != null;
                if (cancel != null) ActionButton("取消", cancel);
                Closed += (sender, args) => ClosedAlready = true;
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
            if (owner == null) throw new ArgumentNullException(nameof(owner));
            owner.Dispatcher.VerifyAccess();
            if (!owner.IsVisible) return new UtenBusyDialog(null);
            Entry value;
            if (!active.TryGetValue(owner, out value))
            {
                value = new Entry { Owner = owner, Enabled = owner.IsEnabled, Window = new BusyWindow(owner, title, cancel) };
                active.Add(owner, value);
                try { owner.IsEnabled = false; value.Window.Show(); }
                catch { active.Remove(owner); owner.IsEnabled = value.Enabled; throw; }
            }
            value.Leases++;
            return new UtenBusyDialog(value);
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
