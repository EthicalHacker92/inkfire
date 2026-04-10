import { useState } from "react";

// TODO (Session 2): wire POST /api/transfer, show progress, duplicate warning
export default function DropZone() {
  const [dragging, setDragging] = useState(false);

  return (
    <div
      className={`dropzone ${dragging ? "dropzone--active" : ""}`}
      onDragOver={(e) => { e.preventDefault(); setDragging(true); }}
      onDragLeave={() => setDragging(false)}
      onDrop={(e) => { e.preventDefault(); setDragging(false); }}
    >
      <p>Drop .cbz, .cbr, .epub, .mobi files here</p>
      <p style={{ color: "var(--text-muted)", fontSize: "0.8rem", marginTop: "0.5rem" }}>
        Transfer implementation coming in Session 2
      </p>
    </div>
  );
}
