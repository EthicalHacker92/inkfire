const express = require("express");
const cors    = require("cors");
const path    = require("path");

const libraryRouter   = require("./routes/library");
const statsRouter     = require("./routes/stats");
const highlightsRouter = require("./routes/highlights");
const transferRouter  = require("./routes/transfer");
const goalsRouter     = require("./routes/goals");
const { dbExists, STATS_DB } = require("./db");

const app  = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());

// API routes
app.use("/api/library",    libraryRouter);
app.use("/api/stats",      statsRouter);
app.use("/api/highlights", highlightsRouter);
app.use("/api/transfer",   transferRouter);
app.use("/api/goals",      goalsRouter);

// Health / debug
app.get("/api/health", (req, res) => {
  res.json({
    ok:      true,
    db:      dbExists(),
    db_path: STATS_DB,
  });
});

// Serve React build in production
const CLIENT_DIST = path.join(__dirname, "../client/dist");
app.use(express.static(CLIENT_DIST));
app.get("*", (req, res) => {
  res.sendFile(path.join(CLIENT_DIST, "index.html"));
});

app.listen(PORT, () => {
  console.log(`\n🔥 Digital Firefighter Dashboard`);
  console.log(`   http://localhost:${PORT}`);
  if (!dbExists()) {
    console.warn(`\n⚠  statistics.sqlite3 not found at:`);
    console.warn(`   ${STATS_DB}`);
    console.warn(`   Run Syncthing or set KOREADER_SYNC_PATH\n`);
  }
});
