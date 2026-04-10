const { Router } = require("express");
// TODO (Session 2): proxy file upload to device via SFTP (TransferBridge)
const router = Router();

// POST /api/transfer — proxy file upload to device
router.post("/", (req, res) => {
  res.json({ message: "Implemented in Session 2 (TransferBridge)" });
});

module.exports = router;
