import { useEffect, useState } from "react";
import SeriesCard from "../components/SeriesCard.jsx";

export default function Library() {
  const [books, setBooks] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch("/api/library")
      .then((r) => r.json())
      .then((data) => { setBooks(data); setLoading(false); })
      .catch(() => setLoading(false));
  }, []);

  // Group flat book list by series
  const grouped = books.reduce((acc, book) => {
    const key = book.series || book.title;
    if (!acc[key]) acc[key] = [];
    acc[key].push(book);
    return acc;
  }, {});

  if (loading) return <p style={{ color: "var(--text-muted)" }}>Loading library…</p>;
  if (!books.length) return <p style={{ color: "var(--text-muted)" }}>No books found. Is Syncthing synced?</p>;

  return (
    <div>
      <h2 style={{ marginBottom: "1rem" }}>Library</h2>
      <div className="series-grid">
        {Object.entries(grouped).map(([series, vols]) => (
          <SeriesCard key={series} series={series} volumes={vols} />
        ))}
      </div>
    </div>
  );
}
