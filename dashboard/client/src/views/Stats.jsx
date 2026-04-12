import { useEffect, useState } from "react";
import HeatmapChart from "../components/HeatmapChart.jsx";

export default function Stats() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch("/api/stats")
      .then(r => r.json())
      .then(d => { setData(d); setLoading(false); })
      .catch(() => setLoading(false));
  }, []);

  if (loading) return <p className="muted">Loading stats…</p>;
  if (!data?.synced) return (
    <div className="empty-state">
      <p>No stats yet — open some books on your Kobo first.</p>
    </div>
  );

  const { totals, heatmap, streak, top_series, speed_trend } = data;

  return (
    <div>
      <div className="stat-row">
        <div className="stat-card">
          <span className="stat-value">{totals.hours}h {totals.minutes}m</span>
          <span className="stat-label">Total read time</span>
        </div>
        <div className="stat-card">
          <span className="stat-value">{totals.total_pages?.toLocaleString()}</span>
          <span className="stat-label">Pages read</span>
        </div>
        <div className="stat-card">
          <span className="stat-value">{totals.total_books}</span>
          <span className="stat-label">Books</span>
        </div>
        <div className="stat-card">
          <span className="stat-value">{streak.current}</span>
          <span className="stat-label">Day streak</span>
        </div>
      </div>

      <section className="section">
        <h3>Reading Heatmap — last 365 days</h3>
        <HeatmapChart data={heatmap || []} />
      </section>

      {top_series?.length > 0 && (
        <section className="section">
          <h3>Top Series by Time</h3>
          <div className="top-list">
            {top_series.map((s, i) => {
              const hrs = Math.floor(s.seconds / 3600);
              const mins = Math.floor((s.seconds % 3600) / 60);
              return (
                <div key={i} className="top-item">
                  <span className="top-rank">{i + 1}</span>
                  <span className="top-name">{s.name}</span>
                  <span className="top-value">{hrs}h {mins}m</span>
                </div>
              );
            })}
          </div>
        </section>
      )}

      {speed_trend?.length > 0 && (
        <section className="section">
          <h3>Reading Speed — pages / hour (12 weeks)</h3>
          <div className="speed-bars">
            {speed_trend.map((w, i) => (
              <div key={i} className="speed-bar-wrap" title={`${w.week}: ${w.pph} p/h`}>
                <div
                  className="speed-bar"
                  style={{ height: `${Math.min(100, (w.pph / 60) * 100)}%` }}
                />
                <span className="speed-label">{w.week.slice(-2)}</span>
              </div>
            ))}
          </div>
        </section>
      )}
    </div>
  );
}
