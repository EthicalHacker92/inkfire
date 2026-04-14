/** Compute current and longest reading streak from a heatmap array.
 *  heatmap: [{ day: "YYYY-MM-DD", seconds: N }, ...]
 *  MIN_SECONDS: minimum seconds in a day to count as an active reading day.
 */
function computeStreak(heatmap, MIN_SECONDS = 60) {
  if (!heatmap || !heatmap.length) {
    return { current: 0, longest: 0, last_read: null };
  }

  const today  = new Date().toISOString().slice(0, 10);
  const active = new Set(
    heatmap.filter(r => r.seconds >= MIN_SECONDS).map(r => r.day)
  );

  // Current streak: walk backwards from today
  let current = 0;
  const d = new Date(today);
  while (active.has(d.toISOString().slice(0, 10))) {
    current++;
    d.setDate(d.getDate() - 1);
  }

  // Longest streak: single sorted pass
  const days = [...active].sort();
  let longest = 0, run = 0;
  for (let i = 0; i < days.length; i++) {
    if (i === 0) { run = 1; continue; }
    const prev = new Date(days[i - 1]);
    prev.setDate(prev.getDate() + 1);
    run = prev.toISOString().slice(0, 10) === days[i] ? run + 1 : 1;
    longest = Math.max(longest, run);
  }
  longest = Math.max(longest, run, current);

  return { current, longest, last_read: days[days.length - 1] || null };
}

module.exports = { computeStreak };
