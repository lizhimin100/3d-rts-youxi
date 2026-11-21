namespace WarIsland.Model
{
    /// <summary>
    /// 确定性随机数（xorshift32）—— Model 层唯一随机源。
    ///
    /// 不用 System.Random / Godot RNG：推演必须"同种子 + 同输入 = 同输出"，
    /// 换宿主、换 .NET 版本都不许漂。
    /// </summary>
    public sealed class Rng
    {
        private uint _state = 1;

        public Rng(int seed)
        {
            Reseed(seed);
        }

        public void Reseed(int seed)
        {
            unchecked
            {
                _state = (uint)(seed ^ (int)0x9E3779B9) & 0x7FFFFFFFu;
            }
            if (_state == 0) _state = 1;
        }

        public uint NextU32()
        {
            uint x = _state;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            _state = x;
            return x;
        }

        public double NextFloat() => NextU32() / 4294967296.0;

        /// <summary>[a, b] 闭区间整数。</summary>
        public int RangeInt(int a, int b)
        {
            if (b <= a) return a;
            return a + (int)(NextU32() % (uint)(b - a + 1));
        }

        /// <summary>按权重取下标；权重 &lt;= 0 的项不会命中。全 0 时返回 0。</summary>
        public int WeightedIndex(double[] weights)
        {
            if (weights == null || weights.Length == 0) return 0;
            double total = 0.0;
            for (int i = 0; i < weights.Length; i++)
            {
                if (weights[i] > 0.0) total += weights[i];
            }
            if (total <= 0.0) return 0;
            double r = NextFloat() * total;
            double acc = 0.0;
            for (int i = 0; i < weights.Length; i++)
            {
                if (weights[i] > 0.0) acc += weights[i];
                if (r < acc) return i;
            }
            return weights.Length - 1;
        }
    }
}
