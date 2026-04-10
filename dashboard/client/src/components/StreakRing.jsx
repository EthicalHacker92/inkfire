// Circular streak/goal ring — SVG-based
// TODO (Session 4): animate, add flame icon at 100%
export default function StreakRing({ streak, goal, todayMinutes }) {
  const pct = goal ? Math.min(todayMinutes / goal, 1) : 0;
  const r = 54;
  const circ = 2 * Math.PI * r;
  const offset = circ * (1 - pct);

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
        <text x="64" y="60" textAnchor="middle" fill="var(--text)" fontSize="22" fontFamily="Fraunces,serif" fontWeight="700">
          {streak}
        </text>
        <text x="64" y="78" textAnchor="middle" fill="var(--text-muted)" fontSize="11" fontFamily="DM Mono,monospace">
          day streak
        </text>
      </svg>
      <p style={{ color: "var(--text-muted)", fontSize: "0.8rem" }}>
        {todayMinutes} / {goal} min today
      </p>
    </div>
  );
}
