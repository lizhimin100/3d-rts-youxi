using System;
using System.Collections;
using System.Collections.Generic;

namespace WarIsland.Model
{
    /// <summary>
    /// 纯 .NET 字典读取（不依赖引擎、不抛异常）。
    ///
    /// 宿主把 JSON 解析成 <c>Dictionary&lt;string, object&gt;</c> 后交进来；
    /// 缺字段/类型不对一律回退到安全默认，真正的“哪里不对”由各 Validate 收集。
    /// </summary>
    internal static class JVal
    {
        public static IDictionary<string, object> Dict(IDictionary<string, object> d, string key)
        {
            if (d == null || !d.TryGetValue(key, out object v)) return null;
            return v as IDictionary<string, object>;
        }

        public static List<object> List(IDictionary<string, object> d, string key)
        {
            if (d == null || !d.TryGetValue(key, out object v)) return null;
            return AsList(v);
        }

        public static List<object> AsList(object v)
        {
            if (v == null) return null;
            if (v is List<object> list) return list;
            if (v is string) return null;
            if (v is IEnumerable e)
            {
                var outList = new List<object>();
                foreach (var item in e) outList.Add(item);
                return outList;
            }
            return null;
        }

        public static IDictionary<string, object> AsDict(object v)
        {
            return v as IDictionary<string, object>;
        }

        public static string Str(IDictionary<string, object> d, string key, string fallback = "")
        {
            if (d == null || !d.TryGetValue(key, out object v) || v == null) return fallback;
            string s = v.ToString();
            return s ?? fallback;
        }

        public static int Int(IDictionary<string, object> d, string key, int fallback = 0)
        {
            if (d == null || !d.TryGetValue(key, out object v) || v == null) return fallback;
            return ToInt(v, fallback);
        }

        public static double Double(IDictionary<string, object> d, string key, double fallback = 0.0)
        {
            if (d == null || !d.TryGetValue(key, out object v) || v == null) return fallback;
            return ToDouble(v, fallback);
        }

        public static bool Bool(IDictionary<string, object> d, string key, bool fallback = false)
        {
            if (d == null || !d.TryGetValue(key, out object v) || v == null) return fallback;
            return ToBool(v, fallback);
        }

        public static int ToInt(object v, int fallback = 0)
        {
            if (v == null) return fallback;
            try { return Convert.ToInt32(v); }
            catch { return fallback; }
        }

        public static double ToDouble(object v, double fallback = 0.0)
        {
            if (v == null) return fallback;
            try { return Convert.ToDouble(v); }
            catch { return fallback; }
        }

        public static bool ToBool(object v, bool fallback = false)
        {
            if (v == null) return fallback;
            if (v is bool b) return b;
            try { return Convert.ToBoolean(v); }
            catch { return fallback; }
        }

        public static string ToStr(object v, string fallback = "")
        {
            if (v == null) return fallback;
            string s = v.ToString();
            return string.IsNullOrEmpty(s) ? fallback : s;
        }

        public static double[] DoubleArray(IDictionary<string, object> d, string key, int expected = -1)
        {
            var list = List(d, key);
            if (list == null) return null;
            if (expected > 0 && list.Count != expected) return null;
            var outArr = new double[list.Count];
            for (int i = 0; i < list.Count; i++) outArr[i] = ToDouble(list[i]);
            return outArr;
        }

        public static string[] StringArray(IDictionary<string, object> d, string key)
        {
            var list = List(d, key);
            if (list == null) return null;
            var outArr = new string[list.Count];
            for (int i = 0; i < list.Count; i++) outArr[i] = ToStr(list[i]);
            return outArr;
        }
    }
}
