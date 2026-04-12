import { BrowserRouter, NavLink, Routes, Route } from "react-router-dom";
import Library from "./views/Library.jsx";
import Stats from "./views/Stats.jsx";
import Highlights from "./views/Highlights.jsx";
import Goals from "./views/Goals.jsx";
import Transfer from "./views/Transfer.jsx";
import "./App.css";
import "./components/components.css";

const NAV = [
  { to: "/",           label: "Library"    },
  { to: "/stats",      label: "Stats"      },
  { to: "/goals",      label: "Goals"      },
  { to: "/highlights", label: "Highlights" },
  { to: "/transfer",   label: "Transfer"   },
];

export default function App() {
  return (
    <BrowserRouter>
      <div className="app">
        <header className="app-header">
          <span className="app-brand">🔥 Digital Firefighter</span>
          <nav className="app-nav">
            {NAV.map(({ to, label }) => (
              <NavLink
                key={to}
                to={to}
                end={to === "/"}
                className={({ isActive }) => isActive ? "nav-link active" : "nav-link"}
              >
                {label}
              </NavLink>
            ))}
          </nav>
        </header>
        <main className="app-main">
          <Routes>
            <Route path="/"           element={<Library />} />
            <Route path="/stats"      element={<Stats />} />
            <Route path="/goals"      element={<Goals />} />
            <Route path="/highlights" element={<Highlights />} />
            <Route path="/transfer"   element={<Transfer />} />
          </Routes>
        </main>
      </div>
    </BrowserRouter>
  );
}
