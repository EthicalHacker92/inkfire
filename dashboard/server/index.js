const express = require("express");
const cors = require("cors");
const path = require("path");

const libraryRouter = require("./routes/library");
const statsRouter = require("./routes/stats");
const highlightsRouter = require("./routes/highlights");
const transferRouter = require("./routes/transfer");

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());

// API routes
app.use("/api/library", libraryRouter);
app.use("/api/stats", statsRouter);
app.use("/api/highlights", highlightsRouter);
app.use("/api/transfer", transferRouter);

// Serve React build in production
app.use(express.static(path.join(__dirname, "../client/dist")));
app.get("*", (req, res) => {
  res.sendFile(path.join(__dirname, "../client/dist/index.html"));
});

app.listen(PORT, () => {
  console.log(`Digital Firefighter Dashboard running at http://localhost:${PORT}`);
});
