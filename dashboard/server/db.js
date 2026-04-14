const Database = require("better-sqlite3");
const path = require("path");
const os   = require("os");
const fs   = require("fs");

const SYNC_PATH = process.env.KOREADER_SYNC_PATH ||
  path.join(os.homedir(), ".koreader_sync");

const STATS_DB = path.join(SYNC_PATH, "statistics.sqlite3");

// Cache handle + the mtime at open time.
// On each getDb() call we stat the file; if mtime changed (Syncthing resync)
// we close and reopen so queries always see current data.
let _db    = null;
let _mtime = 0;

function getDb() {
  if (!fs.existsSync(STATS_DB)) {
    throw new Error(
      `statistics.sqlite3 not found at ${STATS_DB}.\n` +
      `Run Syncthing or set KOREADER_SYNC_PATH to your sync folder.`
    );
  }

  const mtime = fs.statSync(STATS_DB).mtimeMs;
  if (_db && mtime === _mtime) return _db;   // cache hit, file unchanged

  if (_db) { try { _db.close(); } catch {} } // reopen after Syncthing resync
  _db    = new Database(STATS_DB, { readonly: true });
  _mtime = mtime;
  return _db;
}

function dbExists() {
  return fs.existsSync(STATS_DB);
}

module.exports = { getDb, dbExists, SYNC_PATH, STATS_DB };
