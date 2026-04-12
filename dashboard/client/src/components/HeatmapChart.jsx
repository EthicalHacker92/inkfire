import { useMemo } from "react";

const CELL = 13;   // px per day cell
const GAP  = 2;    // px gap
const WEEKS = 52;

export default function HeatmapChart({ data }) {
  const map = useMemo(() => {
    const m = {};
    for (const r of data) m[r.day] = r.seconds;
    return m;
  }, [data]);

  const { days, weeks, max } = useMemo(() => {
    const today = new Date();
    const d = new Date(today);
    d.setDate(d.getDate() - (WEEKS * 7 - 1));
    const days = [];
    for (let i = 0; i < WEEKS * 7; i++) {
      const key = d.toISOString().slice(0, 10);
      days.push({ key, seconds: map[key] || 0, date: new Date(d) });
      d.setDate(d.getDate() + 1);
    }
    const max = Math.max(...days.map(d => d.seconds), 1);
    const weeks = [];
    for (let w = 0; w < WEEKS; w++) weeks.push(days.slice(w * 7, w * 7 + 7));
    return { days, weeks, max };
  }, [map]);

  if (!data.length) {
    return <p className="muted">No reading data yet.</p>;
  }

  function intensity(seconds) {
    if (seconds === 0) return 0;
    return Math.ceil((seconds / max) * 4);  // 1-4
  }

  const COLORS = [
    "var(--border)",       // 0 = none
    "#bf360c44",           // 1 = light
    "#bf360c88",           // 2 = medium
    "#ff5722bb",           // 3 = strong
    "#ff5722",             // 4 = full
  ];

  const width  = WEEKS * (CELL + GAP);
  const height = 7   * (CELL + GAP);

  return (
    <div style={{ overflowX: "auto" }}>
      <svg
        width={width}
        height={height + 20}
        style={{ display: "block" }}
      >
        {weeks.map((week, wi) =>
          week.map((day, di) => {
            const lvl = intensity(day.seconds);
            const mins = Math.round(day.seconds / 60);
            const title = `${day.key}: ${mins > 0 ? mins + " min" : "no reading"}`;
            return (
              <rect
                key={day.key}
                x={wi * (CELL + GAP)}
                y={di * (CELL + GAP)}
                width={CELL}
                height={CELL}
                rx={2}
                fill={COLORS[lvl]}
              >
                <title>{title}</title>
              </rect>
            );
          })
        )}
        {/* Month labels */}
        {weeks.map((week, wi) => {
          const firstDay = week[0];
          if (!firstDay || firstDay.date.getDate() > 7) return null;
          const month = firstDay.date.toLocaleString("default", { month: "short" });
          return (
            <text
              key={wi}
              x={wi * (CELL + GAP)}
              y={height + 14}
              fontSize={9}
              fill="var(--text-muted)"
              fontFamily="DM Mono, monospace"
            >
              {month}
            </text>
          );
        })}
      </svg>
    </div>
  );
}
