// GitHub-style reading heatmap using recharts
// TODO (Session 4): replace placeholder with full calendar heatmap
export default function HeatmapChart({ data }) {
  if (!data.length) {
    return (
      <div style={{ color: "var(--text-muted)", padding: "2rem 0" }}>
        No reading data yet.
      </div>
    );
  }
  return (
    <div style={{ color: "var(--text-muted)", fontSize: "0.8rem" }}>
      {data.length} days with reading activity — full heatmap implemented in Session 4.
    </div>
  );
}
