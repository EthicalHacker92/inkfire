/** Reusable circular progress ring.
 *  Props: pct (0–100), label1 (big centre text), label2 (small centre text)
 *  Convenience wrapper: streak/goal/todayMinutes for the reading-streak use-case.
 */
export default function StreakRing({ pct, label1, label2, streak, goal, todayMinutes }) {
  // Support both generic (pct/label1/label2) and legacy streak props
  const displayPct = pct !== undefined
    ? pct
    : (goal ? Math.min((todayMinutes / goal) * 100, 100) : 0);

  const text1 = label1 !== undefined ? label1 : String(streak ?? 0);
  const text2 = label2 !== undefined ? label2 : "day streak";

  const r    = 54;
  const circ = 2 * Math.PI * r;
  const offset = circ * (1 - displayPct / 100);

  return (
    <div style={{ display: "inline-flex", flexDirection: "column", alignItems: "center", gap: "0.5rem" }}>
      <svg width="128" height="128" viewBox="0 0 128 128">
        <circle cx="64" cy="64" r={r} fill="none" stroke="var(--border)" strokeWidth="10" />
        <circle
          cx="64" cy="64" r={r} fill="none"
          stroke="var(--accent)" strokeWidth="10"
          strokeDasharray={circ}
          strokeDashoffset={offset}
          strokeLinecap="round"
          transform="rotate(-90 64 64)"
        />
        <text x="64" y="60" textAnchor="middle" fill="var(--text)"
          fontSize="22" fontFamily="Fraunces,serif" fontWeight="700">
          {text1}
        </text>
        <text x="64" y="78" textAnchor="middle" fill="var(--text-muted)"
          fontSize="11" fontFamily="DM Mono,monospace">
          {text2}
        </text>
      </svg>
      {goal !== undefined && (
        <p style={{ color: "var(--text-muted)", fontSize: "0.8rem" }}>
          {todayMinutes} / {goal} min today
        </p>
      )}
    </div>
  );
}
