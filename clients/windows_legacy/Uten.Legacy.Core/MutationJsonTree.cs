using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;

namespace Uten.Legacy.Core
{
    /// <summary>Bounded DTO syntax tree, preserving each numeric lexeme. Only JSON primitives
    /// used by the audited unit contracts are accepted; no Double conversion or body rewriting.</summary>
    internal sealed class MutationJsonNode
    {
        internal string Raw;
        internal object Value;
        internal Dictionary<string, MutationJsonNode> Object
        { get { return Value as Dictionary<string, MutationJsonNode> ?? throw new FormatException(); } }
        internal List<MutationJsonNode> Array
        { get { return Value as List<MutationJsonNode> ?? throw new FormatException(); } }
    }
    internal sealed class MutationJsonNumber
    {
        internal readonly string Lexeme;
        internal MutationJsonNumber(string lexeme) { Lexeme = lexeme; }
    }

    internal static class MutationJsonTree
    {
        internal static MutationJsonNode Parse(string text, int maximumBytes, bool preserveControls = false, int maximumNodes = 4096, bool allowNegativeIntegers = false, bool allowDecimalLexemes = false)
        {
            if (text == null || new UTF8Encoding(false, true).GetByteCount(text) > maximumBytes) throw new FormatException();
            var reader = new Reader(text, preserveControls, maximumNodes, allowNegativeIntegers, allowDecimalLexemes);
            var result = reader.Value(0);
            reader.White();
            if (!reader.End) throw new FormatException();
            return result;
        }
        internal static void Keys(Dictionary<string, MutationJsonNode> value, params string[] allowed)
        { if (value.Keys.Any(key => !allowed.Contains(key, StringComparer.Ordinal))) throw new FormatException(); }
        internal static MutationJsonNode Required(Dictionary<string, MutationJsonNode> value, string key)
        { MutationJsonNode node; if (!value.TryGetValue(key, out node)) throw new FormatException(); return node; }
        internal static string Text(MutationJsonNode node, bool required = false, int maximumLength = 16384)
        {
            if (node.Value != null && !(node.Value is string)) throw new FormatException();
            var value = node.Value as string;
            if (value?.Length > maximumLength || (required && String.IsNullOrWhiteSpace(value))) throw new FormatException();
            return value;
        }
        internal static long Integer(MutationJsonNode node, long minimum, long maximum)
        { if (!(node.Value is long) || (long)node.Value < minimum || (long)node.Value > maximum) throw new FormatException(); return (long)node.Value; }
        internal static string Uuid(MutationJsonNode node)
        {
            var value = Text(node, true, 36); Guid id;
            if (!Guid.TryParseExact(value, "D", out id) || id == Guid.Empty) throw new FormatException();
            return id.ToString("D");
        }

        private sealed class Reader
        {
            private readonly string text;
            private readonly bool preserveControls;
            private readonly int maximumNodes;
            private readonly bool allowNegativeIntegers;
            private readonly bool allowDecimalLexemes;
            private int position, nodes;
            internal Reader(string text, bool preserveControls, int maximumNodes, bool allowNegativeIntegers, bool allowDecimalLexemes)
            { this.text = text; this.preserveControls = preserveControls; this.maximumNodes = maximumNodes; this.allowNegativeIntegers = allowNegativeIntegers; this.allowDecimalLexemes = allowDecimalLexemes; }
            internal bool End { get { return position == text.Length; } }
            internal void White() { while (position < text.Length && (text[position] == ' ' || text[position] == '\r' || text[position] == '\n' || text[position] == '\t')) position++; }
            internal MutationJsonNode Value(int depth)
            {
                White(); var start = position;
                if (++nodes > maximumNodes || depth > 16 || position >= text.Length) throw new FormatException();
                object value;
                if (text[position] == '{')
                {
                    position++; White(); var fields = new Dictionary<string, MutationJsonNode>(StringComparer.Ordinal);
                    if (Try('}')) value = fields;
                    else
                    {
                        while (true)
                        {
                            White(); var key = String(false); White(); Take(':');
                            if (fields.ContainsKey(key)) throw new FormatException();
                            fields.Add(key, Value(depth + 1)); White();
                            if (Try('}')) break;
                            Take(',');
                        }
                        value = fields;
                    }
                }
                else if (text[position] == '[')
                {
                    position++; White(); var items = new List<MutationJsonNode>();
                    if (!Try(']')) while (true)
                    {
                        items.Add(Value(depth + 1)); White(); if (Try(']')) break; Take(',');
                    }
                    value = items;
                }
                else if (text[position] == '"') value = String(preserveControls);
                else
                {
                    while (position < text.Length && text[position] != ',' && text[position] != '}' && text[position] != ']'
                        && text[position] != ' ' && text[position] != '\r' && text[position] != '\n' && text[position] != '\t') position++;
                    var token = text.Substring(start, position - start); long number;
                    if (token == "null") value = null;
                    else if (token == "true") value = true;
                    else if (token == "false") value = false;
                    else if (System.Text.RegularExpressions.Regex.IsMatch(token, allowNegativeIntegers ? "^-?(0|[1-9][0-9]*)$" : "^(0|[1-9][0-9]*)$")
                        && Int64.TryParse(token, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out number)) value = number;
                    else if (allowDecimalLexemes && System.Text.RegularExpressions.Regex.IsMatch(token, "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$"))
                        value = new MutationJsonNumber(token);
                    else throw new FormatException();
                }
                return new MutationJsonNode { Raw = text.Substring(start, position - start), Value = value };
            }
            private string String(bool controls)
            {
                var start = position; Take('"');
                while (position < text.Length)
                {
                    var character = text[position++];
                    if (character < 32) throw new FormatException();
                    if (character == '\\')
                    {
                        if (position >= text.Length) throw new FormatException();
                        var escape = text[position++];
                        if (escape == 'u')
                        {
                            for (var i = 0; i < 4; i++)
                                if (position >= text.Length || !Uri.IsHexDigit(text[position++])) throw new FormatException();
                        }
                        else if ("\"\\/bfnrt".IndexOf(escape) < 0) throw new FormatException();
                        continue;
                    }
                    if (character != '"') continue;
                    var value = new JavaScriptSerializer().DeserializeObject(text.Substring(start, position - start)) as string;
                    if (value == null || (!controls && value.Any(Char.IsControl))) throw new FormatException();
                    new UTF8Encoding(false, true).GetByteCount(value);
                    return value;
                }
                throw new FormatException();
            }
            private bool Try(char value) { if (position < text.Length && text[position] == value) { position++; return true; } return false; }
            private void Take(char value) { if (!Try(value)) throw new FormatException(); }
        }
    }
}
