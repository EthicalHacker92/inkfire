import { useEffect, useState } from "react";
import HeatmapChart from "../components/HeatmapChart.jsx";

export default function Stats() {
  const [data, setData] = useState(null);

  useEffect(() => {
    fetch("/api/stats").then((r) => r.json()).then(setData);
  }, []);

  if (!data) return <p style={{ color: "var(--text-muted)" }}>Loading stats…</p>;

  const hrs = Math.floor((data.totals?.total_seconds || 0) / 3600);
  const mins = Math.floor(((data.totals?.total_seconds || 0) % 3600) / 60);

  return (
    <div>
      <h2 style={{ marginBottom: "1rem" }}>Stats</h2>
      <div className="stat-row">
        <div className="stat-card">
          <span className="stat-value">{hrs}h {mins}m</span>
          <span className="stat-label">Total reading time</span>
        </div>
        <div className="stat-card">
          <span className="stat-value">{data.totals?.total_pages?.toLocaleString() ?? 0}</span>
          <span className="stat-label">Pages read</span>
        </div>
        <div className="stat-card">
          <span className="stat-value">{data.totals?.total_books ?? 0}</span>
          <span className="stat-label">Books in library</span>
        </div>
      </div>
      <h3 style={{ margin: "2rem 0 1rem" }}>Reading Heatmap</h3>
      <HeatmapChart data={data.heatmap || []} />
    </div>
  );
}
