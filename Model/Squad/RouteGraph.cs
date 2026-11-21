using System;
using System.Collections.Generic;
using Vec2 = System.Numerics.Vector2;

namespace WarIsland.Model
{
    /// <summary>
    /// 小队行军路径图 —— 沿地图底壳导出的**脊线（spine / Path3D 等效）路径点**做 A*，
    /// 再按"走廊宽度"平滑，供小队质心跟随。
    ///
    /// 口径（2026-11-21）：
    ///   · 输入是**游戏数值**的折线点（Screens 从 shell.spine.points 米 → R1 换算后传来）；
    ///   · 图 = 脊线相邻点 + 隔点跳边；A* 用欧氏距离做启发，平局按索引稳定排序（确定性）；
    ///   · 平滑只允许"捷径仍在脊线走廊内"的删点：这样小队会沿脊线走，而不是抄一条斜穿战场的直线；
    ///   · **建筑不进入这张图**：战斗阶段建筑不阻挡小队寻路（格子上限 4~6 米，小队半径 1.5~2.4 米，
    ///     绕建筑只会把队形挤散；这是设计口径，不是遗漏）；
    ///   · 局部避障由 SquadBattle 的质心分离（圆-圆位置约束）负责，这里只管"往哪走"。
    /// </summary>
    public sealed class SquadRouteGraph
    {
        private readonly List<Vec2> _ridge = new List<Vec2>();
        private readonly double _minX;
        private readonly double _maxX;
        private readonly double _minY;
        private readonly double _maxY;
        private readonly double _corridor;

        public SquadRouteGraph(IEnumerable<Vec2> ridge, double minX, double maxX, double minY, double maxY, double corridor)
        {
            if (ridge != null)
            {
                foreach (var p in ridge) _ridge.Add(p);
            }
            _minX = Math.Min(minX, maxX);
            _maxX = Math.Max(minX, maxX);
            _minY = Math.Min(minY, maxY);
            _maxY = Math.Max(minY, maxY);
            _corridor = corridor > 0.0 ? corridor : 120.0;
        }

        public bool Valid => _ridge.Count >= 2;
        public IReadOnlyList<Vec2> Ridge => _ridge;
        public double Corridor => _corridor;

        /// <summary>规划一条 from → to 的路径（含起终点，游戏数值）。</summary>
        public List<Vec2> Plan(Vec2 from, Vec2 to)
        {
            var path = new List<Vec2>();
            if (!Valid)
            {
                path.Add(from);
                path.Add(to);
                return path;
            }

            int n = _ridge.Count;
            // 虚拟起点 n / 终点 n+1
            int total = n + 2;
            var nodes = new List<Vec2>(total);
            for (int i = 0; i < n; i++) nodes.Add(_ridge[i]);
            nodes.Add(from);
            nodes.Add(to);

            var best = new double[total];
            var prev = new int[total];
            var closed = new bool[total];
            for (int i = 0; i < total; i++)
            {
                best[i] = double.MaxValue;
                prev[i] = -1;
            }
            best[n] = 0.0;

            int endNear = NearestRidgeIndex(to);

            for (int iter = 0; iter < total; iter++)
            {
                int u = -1;
                double uCost = double.MaxValue;
                for (int i = 0; i < total; i++)
                {
                    if (closed[i] || best[i] >= double.MaxValue) continue;
                    if (best[i] < uCost - 1e-9 || (Math.Abs(best[i] - uCost) <= 1e-9 && i < u))
                    {
                        u = i;
                        uCost = best[i];
                    }
                }
                if (u < 0) break;
                if (u == n + 1) break;
                closed[u] = true;

                foreach (int v in Neighbours(u, n, from, to, endNear))
                {
                    if (v < 0 || v >= total || closed[v]) continue;
                    double w = Vec(nodes[u], nodes[v]);
                    if (w <= 1e-9) continue;
                    double cand = best[u] + w;
                    if (cand + 1e-9 < best[v])
                    {
                        best[v] = cand;
                        prev[v] = u;
                    }
                }
            }

            if (prev[n + 1] < 0)
            {
                // 图不连通（正常不会发生）：退回直线
                path.Add(from);
                path.Add(to);
                return path;
            }

            var chain = new List<int>();
            int cur = n + 1;
            int guard = 0;
            while (cur >= 0 && guard++ < total + 4)
            {
                chain.Add(cur);
                if (cur == n) break;
                cur = prev[cur];
            }
            chain.Reverse();

            var raw = new List<Vec2>();
            for (int i = 0; i < chain.Count; i++) raw.Add(nodes[chain[i]]);
            return StringPull(raw);
        }

        private IEnumerable<int> Neighbours(int u, int n, Vec2 from, Vec2 to, int endNear)
        {
            if (u < n)
            {
                if (u + 1 < n) yield return u + 1;
                if (u - 1 >= 0) yield return u - 1;
                if (u + 2 < n && Inside(_ridge[u], _ridge[u + 2])) yield return u + 2;
                if (u - 2 >= 0 && Inside(_ridge[u], _ridge[u - 2])) yield return u - 2;
                // 只有"离目标最近的那两个脊线点"能接出口，避免 A* 从第一个点直接斜穿到终点
                if (u == endNear) yield return n + 1;
                if (Math.Abs(u - endNear) == 1 && Inside(_ridge[u], to)) yield return n + 1;
                yield break;
            }
            if (u == n)
            {
                int bestI = NearestRidgeIndex(from);
                yield return bestI;
                if (bestI + 1 < n) yield return bestI + 1;
                if (bestI - 1 >= 0) yield return bestI - 1;
                yield break;
            }
            // 终点：只进不出
        }

        private int NearestRidgeIndex(Vec2 p)
        {
            int bestI = 0;
            double bestD = double.MaxValue;
            for (int i = 0; i < _ridge.Count; i++)
            {
                double d = Vec(p, _ridge[i]);
                if (d < bestD)
                {
                    bestD = d;
                    bestI = i;
                }
            }
            return bestI;
        }

        private List<Vec2> StringPull(List<Vec2> pts)
        {
            if (pts.Count <= 2) return pts;
            var cur = new List<Vec2>(pts);
            bool changed = true;
            int guard = 0;
            while (changed && guard++ < 32)
            {
                changed = false;
                for (int i = 1; i < cur.Count - 1; i++)
                {
                    if (!Inside(cur[i - 1], cur[i + 1])) continue;
                    if (MaxDeviation(cur[i - 1], cur[i + 1]) > _corridor) continue;
                    cur.RemoveAt(i);
                    changed = true;
                    break;
                }
            }
            return cur;
        }

        /// <summary>路径总长（游戏数值）。</summary>
        public double PathLength(IReadOnlyList<Vec2> path)
        {
            if (path == null || path.Count < 2) return 0.0;
            double sum = 0.0;
            for (int i = 1; i < path.Count; i++) sum += Vec(path[i - 1], path[i]);
            return sum;
        }

        /// <summary>点是否在可走矩形内。</summary>
        public bool Contains(Vec2 p)
        {
            return p.X >= _minX && p.X <= _maxX && p.Y >= _minY && p.Y <= _maxY;
        }

        /// <summary>按半径夹取到可走矩形内。</summary>
        public Vec2 ClampPoint(Vec2 p, double radius)
        {
            double r = Math.Max(radius, 0.0);
            double x = Clamp(p.X, _minX + r, _maxX - r);
            double y = Clamp(p.Y, _minY + r, _maxY - r);
            return new Vec2((float)x, (float)y);
        }

        /// <summary>到脊线的最短距离（游戏数值）。</summary>
        public double DistanceToRidge(Vec2 p)
        {
            if (_ridge.Count == 0) return double.MaxValue;
            if (_ridge.Count == 1) return Vec(p, _ridge[0]);
            double best = double.MaxValue;
            for (int i = 1; i < _ridge.Count; i++)
            {
                double d = DistanceToSegment(p, _ridge[i - 1], _ridge[i]);
                if (d < best) best = d;
            }
            return best;
        }

        private bool Inside(Vec2 a, Vec2 b)
        {
            for (int k = 0; k <= 8; k++)
            {
                double t = k / 8.0;
                var p = new Vec2((float)(a.X + (b.X - a.X) * t), (float)(a.Y + (b.Y - a.Y) * t));
                if (!Contains(p)) return false;
            }
            return true;
        }

        private double MaxDeviation(Vec2 a, Vec2 b)
        {
            double max = 0.0;
            for (int k = 0; k <= 8; k++)
            {
                double t = k / 8.0;
                var p = new Vec2((float)(a.X + (b.X - a.X) * t), (float)(a.Y + (b.Y - a.Y) * t));
                double d = DistanceToRidge(p);
                if (d > max) max = d;
            }
            return max;
        }

        private static double DistanceToSegment(Vec2 p, Vec2 a, Vec2 b)
        {
            double abx = b.X - a.X;
            double aby = b.Y - a.Y;
            double len2 = abx * abx + aby * aby;
            if (len2 <= 1e-12) return Vec(p, a);
            double t = ((p.X - a.X) * abx + (p.Y - a.Y) * aby) / len2;
            if (t < 0.0) t = 0.0;
            if (t > 1.0) t = 1.0;
            var q = new Vec2((float)(a.X + abx * t), (float)(a.Y + aby * t));
            return Vec(p, q);
        }

        private static double Vec(Vec2 a, Vec2 b)
        {
            double dx = b.X - a.X;
            double dy = b.Y - a.Y;
            return Math.Sqrt(dx * dx + dy * dy);
        }

        private static double Clamp(double v, double lo, double hi)
        {
            if (hi < lo) return (lo + hi) * 0.5;
            return v < lo ? lo : (v > hi ? hi : v);
        }
    }
}
