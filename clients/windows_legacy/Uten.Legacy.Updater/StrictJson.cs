using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace Uten.Legacy.Updater
{
    internal static class StrictJson
    {
        internal static Dictionary<string, object> Read(byte[] bytes)
        {
            if (bytes.Length > 65536) throw new InvalidDataException("JSON metadata exceeds its limit.");
            try
            {
                var text = new UTF8Encoding(false, true).GetString(bytes).TrimStart('\uFEFF');
                new UniqueKeys(text).Check();
                var result = new JavaScriptSerializer { MaxJsonLength = 65536, RecursionLimit = 24 }.DeserializeObject(text) as Dictionary<string, object>;
                if (result == null) throw new InvalidDataException("Expected JSON object.");
                return result;
            }
            catch (Exception error) when (error is ArgumentException || error is InvalidOperationException)
            { throw new InvalidDataException("Invalid JSON metadata."); }
        }
        internal static byte[] Write(object value) { return Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(value)); }
        internal static string Text(Dictionary<string, object> value, string key, int limit)
        {
            object raw; var text = value.TryGetValue(key, out raw) ? raw as string : null;
            if (String.IsNullOrWhiteSpace(text) || text.Length > limit) throw new InvalidDataException("Invalid string metadata: " + key);
            foreach (var character in text) if (Char.IsControl(character)) throw new InvalidDataException("Invalid string metadata.");
            return text;
        }
        internal static long Integer(Dictionary<string, object> value, string key, long minimum, long maximum)
        {
            object raw;
            if (!value.TryGetValue(key, out raw) || (!(raw is int) && !(raw is long))) throw new InvalidDataException("Invalid integer metadata: " + key);
            var number = Convert.ToInt64(raw);
            if (number < minimum || number > maximum) throw new InvalidDataException("Integer metadata outside range: " + key);
            return number;
        }
        internal static void Keys(Dictionary<string, object> value, IEnumerable<string> required, params string[] optional)
        {
            var allowed = new HashSet<string>(required, StringComparer.Ordinal);
            foreach (var key in allowed) if (!value.ContainsKey(key)) throw new InvalidDataException("Missing metadata field: " + key);
            foreach (var key in optional) allowed.Add(key);
            foreach (var key in value.Keys) if (!allowed.Contains(key)) throw new InvalidDataException("Unknown metadata field.");
        }
        private sealed class UniqueKeys
        {
            private static readonly Regex Number = new Regex(@"\G-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?");
            private readonly string text; private int cursor;
            internal UniqueKeys(string text) { this.text = text; }
            internal void Check() { Value(0); Space(); if (cursor != text.Length) throw Invalid(); }
            private Exception Invalid() { return new InvalidDataException("Invalid or duplicate JSON metadata."); }
            private void Space() { while (cursor < text.Length && " \r\n\t".IndexOf(text[cursor]) >= 0) cursor++; }
            private char Peek() { Space(); return cursor < text.Length ? text[cursor] : '\0'; }
            private void Require(char value) { if (Peek() != value) throw Invalid(); cursor++; }
            private string String()
            {
                Space(); var start = cursor; Require('"'); var closed = false;
                while (cursor < text.Length)
                {
                    var value = text[cursor++];
                    if (value == '"') { closed = true; break; }
                    if (value < 32) throw Invalid();
                    if (value == '\\') { if (cursor == text.Length) throw Invalid(); cursor++; }
                }
                if (!closed) throw Invalid();
                return new JavaScriptSerializer().Deserialize<string>(text.Substring(start, cursor - start));
            }
            private void Value(int depth)
            {
                if (depth > 20) throw Invalid();
                var first = Peek();
                if (first == '{')
                {
                    cursor++; var keys = new HashSet<string>(StringComparer.Ordinal);
                    if (Peek() == '}') { cursor++; return; }
                    while (true)
                    {
                        if (!keys.Add(String())) throw Invalid(); Require(':'); Value(depth + 1);
                        if (Peek() == '}') { cursor++; return; } Require(',');
                    }
                }
                if (first == '[')
                {
                    cursor++; if (Peek() == ']') { cursor++; return; }
                    while (true) { Value(depth + 1); if (Peek() == ']') { cursor++; return; } Require(','); }
                }
                if (first == '"') { String(); return; }
                foreach (var atom in new[] { "true", "false", "null" })
                    if (cursor <= text.Length - atom.Length && System.String.Compare(text, cursor, atom, 0, atom.Length, StringComparison.Ordinal) == 0)
                    { cursor += atom.Length; return; }
                var match = Number.Match(text, cursor);
                if (!match.Success || match.Index != cursor) throw Invalid(); cursor += match.Length;
            }
        }
    }
}
