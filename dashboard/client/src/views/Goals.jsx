import StreakRing from "../components/StreakRing.jsx";

// TODO (Session 5): wire to ReadingVault /api/goals endpoint
export default function Goals() {
  return (
    <div>
      <h2 style={{ marginBottom: "1rem" }}>Goals</h2>
      <p style={{ color: "var(--text-muted)", marginBottom: "2rem" }}>
        ReadingVault plugin required — implemented in Session 5.
      </p>
      <StreakRing streak={0} goal={30} todayMinutes={0} />
    </div>
  );
}
