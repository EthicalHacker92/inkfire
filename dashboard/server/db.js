const Database = require("better-sqlite3");
const path = require("path");
const os = require("os");
const fs = require("fs");

const SYNC_PATH = process.env.KOREADER_SYNC_PATH ||
  path.join(os.homedir(), ".koreader_sync");

const STATS_DB = path.join(SYNC_PATH, "statistics.sqlite3");

let _db = null;

function getDb() {
  if (_db) return _db;

  if (!fs.existsSync(STATS_DB)) {
    throw new Error(
      `statistics.sqlite3 not found at ${STATS_DB}.\n` +
      `Run Syncthing or set KOREADER_SYNC_PATH to your sync folder.`
    );
  }

  _db = new Database(STATS_DB, { readonly: true });
  return _db;
}

/** Returns true if the DB file exists and is readable. */
function dbExists() {
  return fs.existsSync(STATS_DB);
}

module.exports = { getDb, dbExists, SYNC_PATH, STATS_DB };
