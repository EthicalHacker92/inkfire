import { useEffect, useState } from "react";
import DropZone from "../components/DropZone.jsx";

export default function Transfer() {
  const [status, setStatus] = useState(null);

  useEffect(() => {
    fetch("/api/transfer/status")
      .then(r => r.json())
      .then(setStatus)
      .catch(() => {});
  }, []);

  return (
    <div>
      {status && !status.device_configured && (
        <div className="alert-warning">
          <strong>Device not configured.</strong> Set <code>DEVICE_IP</code> env var
          to your Kobo's IP address, then restart the server.
        </div>
      )}
      {status?.device_host && (
        <p className="muted" style={{ marginBottom: "1rem" }}>
          Sending to <code>{status.device_host}</code> via SFTP.
          CBZ/CBR → <code>/mnt/onboard/manga/</code> · EPUB/PDF → <code>/mnt/onboard/books/</code>
        </p>
      )}
      <DropZone />
    </div>
  );
}
