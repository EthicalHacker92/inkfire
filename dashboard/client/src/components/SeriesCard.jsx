import { useState, useMemo } from "react";

const STATUS_LABEL = { unread: "○", in_progress: "◐", complete: "●" };

export default function SeriesCard({ group, filter }) {
  const [open, setOpen] = useState(false);

  const visibleVols = useMemo(
    () => filter === "all" ? group.volumes : group.volumes.filter(v => v.status === filter),
    [group, filter]
  );

  const totalPct = group.volumes.length > 0
    ? Math.round(
        group.volumes.reduce((s, v) => s + v.pct, 0) / group.volumes.length
      )
    : 0;

  const hrs = Math.floor((group.total_time || 0) / 3600);

  const parts = [];
  if (group.total > 1) parts.push(`${group.total} vols`);
  if (group.unread      > 0) parts.push(`${group.unread} unread`);
  if (group.in_progress > 0) parts.push(`${group.in_progress} reading`);
  if (group.complete    > 0) parts.push(`${group.complete} done`);
  if (hrs > 0)               parts.push(`${hrs}h`);

  return (
    <div className="series-card">
      <div className="series-cover-placeholder">
        {group.series ? (
          <span className="series-cover-initial">
            {group.series.charAt(0).toUpperCase()}
          </span>
        ) : (
          <span className="series-cover-initial">?</span>
        )}
      </div>
      <div className="series-info">
        <p className="series-title">{group.series || "Unsorted"}</p>
        <p className="series-meta">{parts.join(" · ")}</p>
        <div className="series-progress-bar">
          <div className="series-progress-fill" style={{ width: `${totalPct}%` }} />
        </div>
        {group.total > 1 && (
          <button
            className="series-expand-btn"
            onClick={() => setOpen(!open)}
          >
            {open ? "▲ Hide volumes" : `▼ ${visibleVols.length} volume${visibleVols.length !== 1 ? "s" : ""}`}
          </button>
        )}
      </div>

      {open && (
        <div className="series-volumes">
          {visibleVols.map((v, i) => (
            <div key={i} className="vol-row">
              <span className="vol-status" title={v.status}>
                {STATUS_LABEL[v.status] || "○"}
              </span>
              <span className="vol-title">{v.title}</span>
              <span className="vol-pct muted">{v.pct}%</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
