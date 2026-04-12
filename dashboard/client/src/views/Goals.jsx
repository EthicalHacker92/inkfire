import { useEffect, useState } from "react";
import StreakRing from "../components/StreakRing.jsx";

export default function Goals() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetch("/api/goals")
      .then(r => r.json())
      .then(d => { setData(d); setLoading(false); })
      .catch(() => setLoading(false));
  }, []);

  if (loading) return <p className="muted">Loading goals…</p>;
  if (!data?.synced) return (
    <div className="empty-state">
      <p>No data synced yet.</p>
    </div>
  );

  const {
    streak, today_seconds, today_pct, daily_goal_seconds,
    yearly_goal, yearly_complete, yearly_pct,
  } = data;

  const todayMins = Math.floor(today_seconds / 60);
  const goalMins  = Math.floor(daily_goal_seconds / 60);

  return (
    <div>
      <div className="goals-grid">
        <div className="goal-card">
          <h3>Daily Goal</h3>
          <StreakRing
            streak={streak}
            goal={goalMins}
            todayMinutes={todayMins}
          />
          <div className="goal-progress-bar">
            <div className="goal-progress-fill" style={{ width: `${today_pct}%` }} />
          </div>
          <p className="muted" style={{ marginTop: "0.5rem", fontSize: "0.8rem" }}>
            {todayMins} / {goalMins} min today
          </p>
        </div>

        <div className="goal-card">
          <h3>Books This Year</h3>
          <div className="yearly-ring-wrap">
            <svg width="128" height="128" viewBox="0 0 128 128">
              <circle cx="64" cy="64" r="54" fill="none" stroke="var(--border)" strokeWidth="10" />
              <circle
                cx="64" cy="64" r="54" fill="none"
                stroke="var(--accent)" strokeWidth="10"
                strokeDasharray={2 * Math.PI * 54}
                strokeDashoffset={2 * Math.PI * 54 * (1 - yearly_pct / 100)}
                strokeLinecap="round"
                transform="rotate(-90 64 64)"
              />
              <text x="64" y="60" textAnchor="middle" fill="var(--text)" fontSize="22"
                fontFamily="Fraunces,serif" fontWeight="700">{yearly_complete}</text>
              <text x="64" y="78" textAnchor="middle" fill="var(--text-muted)" fontSize="11"
                fontFamily="DM Mono,monospace">of {yearly_goal}</text>
            </svg>
          </div>
          <p className="muted" style={{ textAlign: "center", marginTop: "0.5rem", fontSize: "0.8rem" }}>
            {yearly_pct}% of yearly target
          </p>
        </div>

        <div className="goal-card">
          <h3>Streak</h3>
          <div style={{ textAlign: "center", padding: "1rem 0" }}>
            <div style={{ fontSize: "4rem", fontFamily: "Fraunces,serif", color: "var(--accent)" }}>
              {streak}
            </div>
            <div className="muted" style={{ fontSize: "0.85rem" }}>consecutive days</div>
          </div>
          {streak >= 7 && <p style={{ textAlign: "center", fontSize: "1.5rem" }}>🔥</p>}
        </div>
      </div>
    </div>
  );
}
