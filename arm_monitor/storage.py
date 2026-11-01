import copy
import csv
import io
import json
import sqlite3
import threading
import time
from datetime import datetime
from engine import CHANNELS, DEFAULTS, validate_settings

def stamp():
    return datetime.now().astimezone().isoformat(timespec="seconds")


class Store:
    def __init__(self, path):
        self.path = str(path)
        self.lock = threading.RLock()
        self.db = sqlite3.connect(self.path, check_same_thread=False)
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA busy_timeout=3000")
        self.db.executescript("""
        CREATE TABLE IF NOT EXISTS samples(id INTEGER PRIMARY KEY, epoch REAL NOT NULL,
          timestamp TEXT NOT NULL, source_mode TEXT NOT NULL, scenario TEXT NOT NULL,
          level TEXT NOT NULL, hr REAL, spo2 REAL, body REAL, room REAL,
          valid_mask INTEGER NOT NULL, fpga_state TEXT);
        CREATE INDEX IF NOT EXISTS samples_epoch ON samples(epoch);
        CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY, epoch REAL NOT NULL,
          timestamp TEXT NOT NULL, source_mode TEXT NOT NULL, kind TEXT NOT NULL,
          level TEXT NOT NULL, code TEXT NOT NULL, observed TEXT NOT NULL,
          decision TEXT NOT NULL, next_step TEXT NOT NULL, facts_json TEXT NOT NULL DEFAULT '{}');
        CREATE TABLE IF NOT EXISTS settings(id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL);
        """)
        if "facts_json" not in [row[1] for row in self.db.execute("PRAGMA table_info(events)")]:
            self.db.execute("ALTER TABLE events ADD COLUMN facts_json TEXT NOT NULL DEFAULT '{}'")
        self.db.commit()

    def load_settings(self):
        with self.lock:
            row = self.db.execute("SELECT body FROM settings WHERE id=1").fetchone()
        return validate_settings(json.loads(row[0])) if row else copy.deepcopy(DEFAULTS)

    def save_settings(self, value):
        with self.lock:
            self.db.execute("INSERT OR REPLACE INTO settings(id,body) VALUES(1,?)", (json.dumps(value),))
            self.db.commit()

    def add_sample(self, state, mode, scenario):
        rows = state["channels"]
        values = [rows[ch]["value"] if rows[ch]["valid"] else None for ch in CHANNELS]
        mask = sum(1<<i for i,ch in enumerate(CHANNELS) if rows[ch]["valid"])
        with self.lock:
            self.db.execute("INSERT INTO samples(epoch,timestamp,source_mode,scenario,level,hr,spo2,body,room,valid_mask,fpga_state) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (time.time(),stamp(),mode,scenario,state["level"])+tuple(values)+(mask,state["fpga_state"]))
            self.db.commit()

    def event(self, mode, kind, level, code, observed, decision="", next_step="", facts=None):
        with self.lock:
            cur = self.db.execute("INSERT INTO events(epoch,timestamp,source_mode,kind,level,code,observed,decision,next_step,facts_json) VALUES(?,?,?,?,?,?,?,?,?,?)",
                (time.time(),stamp(),mode,kind,level,code,observed,decision,next_step,json.dumps(facts or {},ensure_ascii=False,allow_nan=False)))
            self.db.commit()
            return cur.lastrowid

    def events(self, limit=150):
        with self.lock:
            cur = self.db.execute("SELECT id,timestamp,source_mode,kind,level,code,observed,decision,next_step,facts_json FROM events ORDER BY id DESC LIMIT ?", (limit,))
            return [dict(zip([d[0] for d in cur.description], row)) for row in cur.fetchall()]

    def history(self, limit=600, mode=None):
        with self.lock:
            cur = self.db.execute("SELECT timestamp,source_mode,hr,spo2,body,room,valid_mask FROM samples WHERE source_mode=? ORDER BY id DESC LIMIT ?", (mode,limit))
            rows = [dict(zip([d[0] for d in cur.description], row)) for row in cur.fetchall()]
        return list(reversed(rows))

    def export(self, kind):
        # Bound export memory on the ARM target; invalid values remain empty.
        if kind not in ("samples", "events"):
            raise ValueError("Unknown export kind")
        if kind == "events":
            sql = "SELECT timestamp,source_mode,kind,level,code,observed,decision,next_step,facts_json FROM events ORDER BY id DESC LIMIT 100000"
        else:
            sql = "SELECT timestamp,source_mode,scenario,level,hr,spo2,body,room,valid_mask,fpga_state FROM samples ORDER BY id DESC LIMIT 100000"
        with self.lock:
            cur = self.db.execute(sql)
            names, rows = [d[0] for d in cur.description], cur.fetchall()
        f = io.StringIO(newline="")
        writer = csv.writer(f)
        writer.writerow(names)
        for row in reversed(rows):
            writer.writerow([("'"+v) if isinstance(v,str) and v.startswith(("=","+","-","@")) else v for v in row])
        return b"\xef\xbb\xbf"+f.getvalue().encode("utf-8")

    def prune(self):
        with self.lock:
            # 默认保存最近7天，事件最多保留两万条，防止SD卡无限增长。
            self.db.execute("DELETE FROM samples WHERE epoch<?", (time.time()-7*86400,))
            self.db.execute("DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 20000)")
            self.db.commit()

    def close(self):
        with self.lock:
            self.db.close()
