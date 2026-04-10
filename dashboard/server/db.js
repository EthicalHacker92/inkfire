const Database = require("better-sqlite3");
const path = require("path");
const os = require("os");

const SYNC_PATH = process.env.KOREADER_SYNC_PATH ||
  path.join(os.homedir(), ".koreader_sync");

const STATS_DB = path.join(SYNC_PATH, "statistics.sqlite3");

let _db = null;

function getDb() {
  if (!_db) {
    _db = new Database(STATS_DB, { readonly: true });
  }
  return _db;
}

module.exports = { getDb, SYNC_PATH };
