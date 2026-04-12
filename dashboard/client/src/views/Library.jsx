import { useEffect, useState } from "react";
import SeriesCard from "../components/SeriesCard.jsx";

const FILTERS = ["all", "unread", "in_progress", "complete"];
const FILTER_LABELS = { all: "All", unread: "Unread", in_progress: "Reading", complete: "Done" };

export default function Library() {
  const [data,    setData]   = useState(null);
  const [loading, setLoading] = useState(true);
  const [filter,  setFilter] = useState("all");
  const [search,  setSearch] = useState("");

  useEffect(() => {
    fetch("/api/library")
      .then(r => r.json())
      .then(d => { setData(d); setLoading(false); })
      .catch(() => setLoading(false));
  }, []);

  if (loading) return <p className="muted">Loading library…</p>;
  if (!data?.synced) return (
    <div className="empty-state">
      <p>No data synced yet.</p>
      <p className="muted">Run Syncthing so your Kobo's KOReader folder syncs to your Mac.</p>
    </div>
  );

  const groups = (data.groups || []).filter(g => {
    if (filter !== "all" && g[filter] === 0) return false;
    if (search && !g.series?.toLowerCase().includes(search.toLowerCase()) &&
        !g.volumes.some(v => v.title?.toLowerCase().includes(search.toLowerCase()))) return false;
    return true;
  });

  return (
    <div>
      <div className="view-toolbar">
        <input
          className="search-input"
          type="search"
          placeholder="Search series or title…"
          value={search}
          onChange={e => setSearch(e.target.value)}
        />
        <div className="filter-tabs">
          {FILTERS.map(f => (
            <button
              key={f}
              className={`filter-tab${filter === f ? " active" : ""}`}
              onClick={() => setFilter(f)}
            >
              {FILTER_LABELS[f]}
            </button>
          ))}
        </div>
      </div>

      {groups.length === 0 ? (
        <p className="muted">No results.</p>
      ) : (
        <div className="series-grid">
          {groups.map((g, i) => (
            <SeriesCard key={g.series || i} group={g} filter={filter} />
          ))}
        </div>
      )}
    </div>
  );
}
