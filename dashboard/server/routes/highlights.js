const { Router } = require("express");
// TODO (Session 5): parse .sdr sidecar .lua files and aggregate into response
const router = Router();

// GET /api/highlights — all highlights across all books
router.get("/", (req, res) => {
  res.json({ highlights: [], message: "Implemented in Session 5 (ClipSync)" });
});

module.exports = router;
