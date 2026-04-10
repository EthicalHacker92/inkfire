import DropZone from "../components/DropZone.jsx";

// TODO (Session 2): wire to /api/transfer + show device library
export default function Transfer() {
  return (
    <div>
      <h2 style={{ marginBottom: "1rem" }}>Transfer</h2>
      <p style={{ color: "var(--text-muted)", marginBottom: "1.5rem" }}>
        Drop files below to send them to your Kobo via TransferBridge.
        Full implementation in Session 2.
      </p>
      <DropZone />
    </div>
  );
}
