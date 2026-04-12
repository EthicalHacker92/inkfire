import { useEffect, useState, useCallback } from "react";

export default function Highlights() {
  const [highlights, setHighlights] = useState([]);
  const [loading,    setLoading]    = useState(true);
  const [query,      setQuery]      = useState("");
  const [copied,     setCopied]     = useState(null);

  const fetchHighlights = useCallback((q) => {
    setLoading(true);
    const url = "/api/highlights" + (q ? `?q=${encodeURIComponent(q)}` : "");
    fetch(url)
      .then(r => r.json())
      .then(d => { setHighlights(d.highlights || []); setLoading(false); })
      .catch(() => setLoading(false));
  }, []);

  useEffect(() => { fetchHighlights(""); }, [fetchHighlights]);

  const handleSearch = (e) => {
    e.preventDefault();
    fetchHighlights(query);
  };

  const copyAll = () => {
    const text = highlights.map(h =>
      `"${h.text}"${h.note ? `\n— ${h.note}` : ""}\n— ${h.book}`
    ).join("\n\n");
    navigator.clipboard.writeText(text).then(() => {
      setCopied("all");
      setTimeout(() => setCopied(null), 2000);
    });
  };

  const copyOne = (h, i) => {
    const text = `"${h.text}"${h.note ? `\n— ${h.note}` : ""}\n— ${h.book}`;
    navigator.clipboard.writeText(text).then(() => {
      setCopied(i);
      setTimeout(() => setCopied(null), 2000);
    });
  };

  return (
    <div>
      <div className="view-toolbar">
        <form onSubmit={handleSearch} style={{ display: "flex", gap: "0.5rem", flex: 1 }}>
          <input
            className="search-input"
            type="search"
            placeholder="Search highlights…"
            value={query}
            onChange={e => setQuery(e.target.value)}
          />
          <button type="submit" className="btn">Search</button>
        </form>
        {highlights.length > 0 && (
          <button className="btn btn-ghost" onClick={copyAll}>
            {copied === "all" ? "Copied!" : `Copy All (${highlights.length})`}
          </button>
        )}
      </div>

      {loading ? (
        <p className="muted">Loading…</p>
      ) : highlights.length === 0 ? (
        <div className="empty-state">
          <p>No highlights found.</p>
          <p className="muted">
            Highlights are read from <code>.sdr</code> sidecar files synced by Syncthing.
          </p>
        </div>
      ) : (
        <div className="highlight-list">
          {highlights.map((h, i) => (
            <div key={i} className="highlight-card">
              <blockquote className="highlight-text">{h.text}</blockquote>
              {h.note && <p className="highlight-note">💬 {h.note}</p>}
              <div className="highlight-meta">
                <span className="highlight-book">{h.book}</span>
                {h.chapter && <span className="highlight-chapter">{h.chapter}</span>}
                {h.page    && <span>p.{h.page}</span>}
              </div>
              <button
                className="btn btn-ghost"
                style={{ marginTop: "0.5rem", fontSize: "0.75rem", padding: "0.25rem 0.75rem" }}
                onClick={() => copyOne(h, i)}
              >
                {copied === i ? "Copied!" : "Copy"}
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
