const { Router }  = require("express");
const multer      = require("multer");
const path        = require("path");
const fs          = require("fs");
const { Client }  = require("ssh2");

const router = Router();

const DEVICE_HOST = process.env.DEVICE_IP   || null;
const DEVICE_PORT = parseInt(process.env.DEVICE_SSH_PORT || "22");
const DEVICE_USER = process.env.DEVICE_USER || "root";
const DEVICE_PASS = process.env.DEVICE_PASS || "";
const MANGA_PATH  = "/mnt/onboard/manga/";
const BOOKS_PATH  = "/mnt/onboard/books/";

const MANGA_EXTS  = new Set([".cbz", ".cbr", ".zip"]);
const BOOKS_EXTS  = new Set([".epub", ".mobi", ".azw", ".azw3", ".fb2", ".pdf"]);

// Store uploaded files in /tmp
const upload = multer({
  dest: "/tmp/inkfire-uploads/",
  limits: { fileSize: 500 * 1024 * 1024 },
});

// POST /api/transfer — upload one or more files to the device via SFTP
router.post("/", upload.array("files"), async (req, res) => {
  if (!DEVICE_HOST) {
    return res.status(503).json({
      error: "Device IP not configured. Set DEVICE_IP environment variable.",
    });
  }

  if (!req.files || req.files.length === 0) {
    return res.status(400).json({ error: "No files provided." });
  }

  const results = [];
  for (const file of req.files) {
    try {
      const dest = getDestPath(file.originalname);
      await sftpUpload(file.path, dest, file.originalname);
      results.push({ filename: file.originalname, status: "ok", dest });
    } catch (err) {
      results.push({ filename: file.originalname, status: "error", message: err.message });
    } finally {
      // Clean up temp file
      fs.unlink(file.path, () => {});
    }
  }

  res.json({ results });
});

// GET /api/transfer/status — device connection check
router.get("/status", (req, res) => {
  res.json({
    device_configured: !!DEVICE_HOST,
    device_host:       DEVICE_HOST,
    device_port:       DEVICE_PORT,
  });
});

function getDestPath(filename) {
  const ext = path.extname(filename).toLowerCase();
  if (MANGA_EXTS.has(ext)) return MANGA_PATH + filename;
  if (BOOKS_EXTS.has(ext)) return BOOKS_PATH + filename;
  return BOOKS_PATH + filename;
}

function sftpUpload(local_path, remote_path, filename) {
  return new Promise((resolve, reject) => {
    const conn = new Client();
    conn.on("ready", () => {
      conn.sftp((err, sftp) => {
        if (err) { conn.end(); return reject(err); }

        sftp.fastPut(local_path, remote_path, (err2) => {
          conn.end();
          if (err2) reject(err2);
          else resolve();
        });
      });
    });
    conn.on("error", reject);
    conn.connect({
      host:     DEVICE_HOST,
      port:     DEVICE_PORT,
      username: DEVICE_USER,
      password: DEVICE_PASS,
      readyTimeout: 8000,
    });
  });
}

module.exports = router;
