using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;

namespace Uten.Legacy.Desktop.Shared
{
    /// <summary>Selection survives pagination within one owning query. The caller clears
    /// this store when that query or security fence retires; names never replace identity.</summary>
    public sealed class PersistentRowSelection<T>
    {
        private readonly Func<T, string> identity;
        private readonly Dictionary<string, T> rows = new Dictionary<string, T>(StringComparer.Ordinal);
        public PersistentRowSelection(Func<T, string> identity) { this.identity = identity ?? throw new ArgumentNullException(nameof(identity)); }
        public int Count { get { return rows.Count; } }
        public IReadOnlyList<T> Values { get { return new ReadOnlyCollection<T>(new List<T>(rows.Values)); } }
        public bool Contains(T row) { return rows.ContainsKey(Key(row)); }
        public void Remember(T row) { rows[Key(row)] = row; }
        public void Forget(T row) { rows.Remove(Key(row)); }
        public void Clear() { rows.Clear(); }
        private string Key(T row)
        {
            string id = identity(row);
            if (String.IsNullOrEmpty(id)) throw new ArgumentException("Selection requires a real record identity.");
            return id;
        }
    }
}
