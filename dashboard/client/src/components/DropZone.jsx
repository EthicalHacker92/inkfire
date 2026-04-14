import { useState, useRef } from "react";

const ACCEPTED = ".cbz,.cbr,.epub,.mobi,.azw,.azw3,.fb2,.pdf,.zip";

export default function DropZone() {
  const [dragging, setDragging]   = useState(false);
  const [queue,    setQueue]      = useState([]);
  const [sending,  setSending]    = useState(false);
  const inputRef = useRef(null);

  function addFiles(files) {
    const next = [...queue];
    for (const f of files) {
      if (!next.find(q => q.file.name === f.name && q.file.size === f.size)) {
        next.push({ file: f, status: "pending", progress: 0, message: "" });
      }
    }
    setQueue(next);
  }

  async function send() {
    setSending(true);

    // Work over indices so we can produce fresh item objects instead of mutating
    for (let i = 0; i < queue.length; i++) {
      if (queue[i].status !== "pending") continue;

      // Mark uploading — spread each item to avoid shared object references
      setQueue(q => q.map((item, idx) =>
        idx === i ? { ...item, status: "uploading" } : item
      ));

      const fd = new FormData();
      fd.append("files", queue[i].file, queue[i].file.name);

      let nextStatus = "error";
      let nextMessage = "";
      try {
        const res  = await fetch("/api/transfer", { method: "POST", body: fd });
        const json = await res.json();
        const r    = json.results?.[0];
        nextStatus  = r?.status  || "error";
        nextMessage = r?.message || r?.dest || "";
      } catch (e) {
        nextMessage = e.message;
      }

      setQueue(q => q.map((item, idx) =>
        idx === i ? { ...item, status: nextStatus, message: nextMessage } : item
      ));
    }
    setSending(false);
  }

  function clear() {
    setQueue(q => q.filter(item => item.status === "uploading"));
  }

  const pending = queue.filter(q => q.status === "pending").length;

  return (
    <div>
      <div
        className={`dropzone${dragging ? " dropzone--active" : ""}`}
        onDragOver={e => { e.preventDefault(); setDragging(true); }}
        onDragLeave={() => setDragging(false)}
        onDrop={e => {
          e.preventDefault();
          setDragging(false);
          addFiles([...e.dataTransfer.files]);
        }}
        onClick={() => inputRef.current?.click()}
      >
        <input
          ref={inputRef}
          type="file"
          multiple
          accept={ACCEPTED}
          style={{ display: "none" }}
          onChange={e => addFiles([...e.target.files])}
        />
        <p style={{ fontSize: "2rem", marginBottom: "0.5rem" }}>📚</p>
        <p>Drop files here or click to browse</p>
        <p className="muted" style={{ fontSize: "0.8rem", marginTop: "0.25rem" }}>
          CBZ · CBR · EPUB · MOBI · PDF · FB2
        </p>
      </div>

      {queue.length > 0 && (
        <>
          <div className="file-queue">
            {queue.map((item, i) => (
              <div key={i} className="file-item">
                <div>
                  <span className="file-name">{item.file.name}</span>
                  <span className="file-size muted"> — {fmtBytes(item.file.size)}</span>
                  {item.message && (
                    <span className="muted" style={{ fontSize: "0.75rem" }}> · {item.message}</span>
                  )}
                </div>
                <span className={`badge badge-${item.status}`}>{item.status}</span>
              </div>
            ))}
          </div>
          <div style={{ display: "flex", gap: "0.5rem", marginTop: "1rem" }}>
            <button className="btn btn-ghost" onClick={clear}>Clear</button>
            <button className="btn" disabled={pending === 0 || sending} onClick={send}>
              {sending ? "Sending…" : `Send ${pending} file${pending !== 1 ? "s" : ""}`}
            </button>
          </div>
        </>
      )}
    </div>
  );
}

function fmtBytes(n) {
  if (n < 1024)         return n + " B";
  if (n < 1024 * 1024)  return (n / 1024).toFixed(1) + " KB";
  return (n / 1024 / 1024).toFixed(1) + " MB";
}
