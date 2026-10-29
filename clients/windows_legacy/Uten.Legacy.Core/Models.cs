using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace Uten.Legacy.Core
{
    public sealed class ApiException : Exception
    {
        public string Code { get; private set; }
        public string UserMessage { get; private set; }
        public int? StatusCode { get; private set; }
        public bool IsSubmissionUnknown { get; private set; }
        public bool HasResponseCode { get; private set; }

        public ApiException(string code, string userMessage, int? statusCode = null,
            bool isSubmissionUnknown = false, bool hasResponseCode = false) : base(userMessage)
        {
            Code = code;
            UserMessage = userMessage;
            StatusCode = statusCode;
            IsSubmissionUnknown = isSubmissionUnknown;
            HasResponseCode = hasResponseCode;
        }
    }

    /// <summary>Matches TokenResponse.UserProfile and the flattened /auth/me response.</summary>
    public sealed class UserProfile
    {
        public string Id { get; private set; }
        public string LoginAccount { get; private set; }
        public string EmployeeId { get; private set; }
        public string Name { get; private set; }
        public string Code { get; private set; }
        public string Department { get; private set; }
        public string Position { get; private set; }
        public bool SuperAdmin { get; private set; }
        public bool MustChangePassword { get; private set; }
        public ReadOnlyCollection<string> Permissions { get; private set; }
        public string BusinessDatasetId { get; private set; }
        public long BusinessResetGeneration { get; private set; }

        public bool HasPermission(string permission)
        {
            return SuperAdmin || (!String.IsNullOrEmpty(permission) && Permissions.Contains(permission));
        }

        internal static UserProfile Parse(Dictionary<string, object> value, bool forcePasswordChange = false)
        {
            var result = new UserProfile
            {
                Id = JsonValue.RequiredString(value, "id", 128),
                LoginAccount = JsonValue.RequiredString(value, "loginAccount", 128),
                EmployeeId = JsonValue.OptionalString(value, "employeeId", 128),
                Name = JsonValue.OptionalString(value, "name", 200),
                Code = JsonValue.OptionalString(value, "code", 128),
                Department = JsonValue.OptionalString(value, "department", 200),
                Position = JsonValue.OptionalString(value, "position", 200),
                SuperAdmin = JsonValue.Boolean(value, "superAdmin"),
                MustChangePassword = JsonValue.Boolean(value, "mustChangePassword") || forcePasswordChange,
                BusinessResetGeneration = JsonValue.Integer(value, "businessResetGeneration", 0, 0, Int64.MaxValue)
            };
            if (value.ContainsKey("businessDatasetId"))
            {
                result.BusinessDatasetId = JsonValue.RequiredString(value, "businessDatasetId", 36);
                if (!Regex.IsMatch(result.BusinessDatasetId, "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"))
                    throw new FormatException("Invalid dataset identity");
            }
            object permissions;
            var entries = value.TryGetValue("permissions", out permissions) ? permissions as object[] : new object[0];
            if (entries == null || entries.Length > 10000) throw new FormatException("Invalid permissions");
            var names = entries.Select(entry => entry as string).ToList();
            if (names.Any(entry => entry == null || entry.Length > 200 || entry.Any(Char.IsControl)))
                throw new FormatException("Invalid permissions");
            result.Permissions = names.Distinct(StringComparer.Ordinal).ToList().AsReadOnly();
            return result;
        }
    }

    internal sealed class AuthResult
    {
        internal string AccessToken;
        internal string RefreshToken;
        internal int ExpiresIn;
        internal UserProfile User;

        internal static AuthResult Parse(string json)
        {
            try
            {
                var root = JsonValue.ParseObject(json);
                var result = new AuthResult
                {
                    AccessToken = JsonValue.RequiredString(root, "accessToken", 16384),
                    RefreshToken = JsonValue.RequiredString(root, "refreshToken", 512),
                    ExpiresIn = (int)JsonValue.Integer(root, "expiresIn", 900, 1, 86400)
                };
                if (!Regex.IsMatch(result.AccessToken, "^[A-Za-z0-9._~-]+$")
                    || !Regex.IsMatch(result.RefreshToken, "^[A-Za-z0-9._~-]+$"))
                    throw new FormatException("Invalid credentials");
                object user;
                if (!root.TryGetValue("user", out user) || !(user is Dictionary<string, object>))
                    throw new FormatException("Missing user");
                result.User = UserProfile.Parse((Dictionary<string, object>)user, JsonValue.Boolean(root, "mustChangePassword"));
                return result;
            }
            catch (Exception error) when (error is FormatException || error is ArgumentException || error is InvalidOperationException)
            { throw new ApiException("INVALID_AUTH_RESPONSE", "登录信息异常，请重新登录。"); }
        }
    }

    internal static class JsonValue
    {
        internal static Dictionary<string, object> ParseObject(string text, int maxLength = 8388608)
        {
            var serializer = new JavaScriptSerializer { MaxJsonLength = maxLength, RecursionLimit = 64 };
            var result = serializer.DeserializeObject(text) as Dictionary<string, object>;
            if (result == null) throw new FormatException("Expected object");
            return result;
        }

        internal static string Serialize(object value)
        {
            return new JavaScriptSerializer { MaxJsonLength = 8388608, RecursionLimit = 64 }.Serialize(value);
        }

        internal static string RequiredString(Dictionary<string, object> value, string key, int limit)
        {
            var result = OptionalString(value, key, limit);
            if (String.IsNullOrWhiteSpace(result)) throw new FormatException("Missing required field");
            return result;
        }

        internal static string OptionalString(Dictionary<string, object> value, string key, int limit)
        {
            object entry;
            if (!value.TryGetValue(key, out entry) || entry == null) return null;
            var result = entry as string;
            if (result == null || result.Length > limit || result.Any(Char.IsControl))
                throw new FormatException("Invalid text field");
            return result;
        }

        internal static bool Boolean(Dictionary<string, object> value, string key)
        {
            object entry;
            if (!value.TryGetValue(key, out entry)) return false;
            if (!(entry is bool)) throw new FormatException("Invalid boolean field");
            return (bool)entry;
        }

        internal static long Integer(Dictionary<string, object> value, string key, long fallback, long minimum, long maximum)
        {
            object entry;
            if (!value.TryGetValue(key, out entry)) return fallback;
            if (!(entry is int) && !(entry is long)) throw new FormatException("Invalid integer field");
            var result = Convert.ToInt64(entry);
            if (result < minimum || result > maximum) throw new FormatException("Integer outside accepted range");
            return result;
        }
    }
}
