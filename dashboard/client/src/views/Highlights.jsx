import { useEffect, useState } from "react";

// TODO (Session 5): full search + Notion/Obsidian export UI
export default function Highlights() {
  const [highlights, setHighlights] = useState([]);

  useEffect(() => {
    fetch("/api/highlights")
      .then((r) => r.json())
      .then((d) => setHighlights(d.highlights || []));
  }, []);

  return (
    <div>
      <h2 style={{ marginBottom: "1rem" }}>Highlights</h2>
      {highlights.length === 0 ? (
        <p style={{ color: "var(--text-muted)" }}>
          ClipSync plugin required for cross-library highlights — implemented in Session 5.
        </p>
      ) : (
        <ul>
          {highlights.map((h, i) => <li key={i}>{h.text}</li>)}
        </ul>
      )}
    </div>
  );
}
