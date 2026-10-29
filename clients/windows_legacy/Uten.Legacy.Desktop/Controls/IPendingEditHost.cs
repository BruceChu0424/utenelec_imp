using System.Windows;

namespace Uten.Legacy.Desktop.Controls
{
    /// <summary>The owning main window retains a close guard even when authentication
    /// retires/replaces the old workspace before its encrypted draft I/O completes.</summary>
    public interface IPendingEditHost
    {
        void TrackPendingEditor(Window editor);
    }
}
