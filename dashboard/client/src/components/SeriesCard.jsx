export default function SeriesCard({ series, volumes }) {
  const total = volumes.length;
  const readPages = volumes.reduce((s, b) => s + (b.total_read_pages || 0), 0);
  const totalPages = volumes.reduce((s, b) => s + (b.pages || 0), 0);
  const pct = totalPages ? Math.round((readPages / totalPages) * 100) : 0;

  return (
    <div className="series-card">
      <div className="series-cover-placeholder" />
      <div className="series-info">
        <p className="series-title">{series}</p>
        <p className="series-meta">{total} vol{total !== 1 ? "s" : ""} · {pct}% read</p>
        <div className="series-progress-bar">
          <div className="series-progress-fill" style={{ width: `${pct}%` }} />
        </div>
      </div>
    </div>
  );
}
