#!/usr/bin/env bash
# make_fake_db.sh — creates a small fake opencode DB for tests.
# Usage: make_fake_db.sh <output.db>
# Schema mirrors the real tables used by the tool (session, message, part).
set -euo pipefail

DB="${1:?Usage: make_fake_db.sh <output.db>}"
rm -f "$DB"

# Long tool output (>500 chars, single line for valid JSON) to exercise truncation.
LONG_OUTPUT="$(printf 'repetition_word_%s ' {1..110})"

sqlite3 "$DB" <<SQL
CREATE TABLE session (
  id text PRIMARY KEY, project_id text NOT NULL, slug text NOT NULL,
  directory text NOT NULL, title text NOT NULL, version text NOT NULL,
  share_url text, parent_id text, agent text, model text, cost real,
  tokens_input integer, tokens_output integer, tokens_reasoning integer,
  tokens_cache_read integer, tokens_cache_write integer,
  time_created integer NOT NULL, time_updated integer NOT NULL,
  time_archived integer, time_compacting integer
);
CREATE TABLE message (
  id text PRIMARY KEY, session_id text NOT NULL,
  time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL
);
CREATE TABLE part (
  id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL,
  time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL
);
CREATE TABLE session_input (
  id text PRIMARY KEY, session_id text NOT NULL, prompt text NOT NULL,
  delivery text NOT NULL, admitted_seq integer NOT NULL, promoted_seq integer,
  time_created integer NOT NULL
);

-- Root A with subagents. tokens_*/cost on the session row are ZERO (like old
-- sessions): the export-time backfill must recover them from the step-finish part.
INSERT INTO session VALUES
 ('ses_A0001','proj1','alpha-alpha','/tmp/projA','Project Alpha','1.0',NULL,NULL,'build','{"id":"model-a","providerID":"opencode"}',
  0,0,0,0,0,0,1789000000000,1789000600000,NULL,NULL),
 ('ses_A0002','proj1','gaps','/tmp/projA','Explore gaps (@explore subagent)','1.0',NULL,'ses_A0001','explore','{"id":"model-b","providerID":"opencode"}',
  0,200,30,0,0,0,1789000100000,1789000200000,NULL,NULL),
 ('ses_A0003','proj1','bugs','/tmp/projA','Find false bugs (@explore subagent)','1.0',NULL,'ses_A0001','explore','{"id":"model-b","providerID":"opencode"}',
  0,300,40,0,0,0,1789000300000,1789000400000,NULL,NULL);
-- Root B with one subagent and one orphan (missing parent)
INSERT INTO session VALUES
 ('ses_B0001','proj2','beta-bravo','/tmp/projB','Project Beta','1.0',NULL,NULL,'build','{"id":"model-a","providerID":"opencode"}',
  0,500,90,0,0,0,1789001000000,1789001600000,NULL,NULL),
 ('ses_B0002','proj2','beta-sub','/tmp/projB','Translate docs (@explore subagent)','1.0',NULL,'ses_B0001','explore','{"id":"model-b","providerID":"opencode"}',
  0,50,10,0,0,0,1789001100000,1789001200000,NULL,NULL),
 -- the orphan is the newest ROOT on BOTH axes (so 'shrink --keep N' picks it
 -- first), but B was used more recently than A: the two axes disagree on the
 -- A/B pair, so all four list --order axes are distinguishable
 ('ses_ORPHAN01','proj3','orphan','/tmp/projC','Orphan subagent (@explore subagent)','1.0',NULL,'ses_MISSING','explore','{"id":"model-b","providerID":"opencode"}',
  0,10,5,0,0,0,1789002000000,1789002100000,NULL,NULL);

-- Messages of root A (with a compaction and summary.diffs)
INSERT INTO message VALUES
 ('msg_A_1','ses_A0001',1789000000000,1789000000000,'{"role":"user","time":{"created":1789000000000},"agent":"build"}'),
 ('msg_A_2','ses_A0001',1789000100000,1789000100000,'{"role":"assistant","time":{"created":1789000100000},"agent":"build"}'),
 ('msg_A_3','ses_A0001',1789000200000,1789000200000,'{"role":"user","time":{"created":1789000200000},"summary":{"diffs":[{"file":"src/a.py","patch":"...","additions":5,"deletions":2,"status":"modified"}]}}'),
 ('msg_A_4','ses_A0001',1789000300000,1789000300000,'{"role":"assistant","time":{"created":1789000300000},"agent":"build"}'),
 ('msg_A_5','ses_A0001',1789000400000,1789000400000,'{"role":"assistant","time":{"created":1789000400000},"summary":true,"agent":"build"}'),
 ('msg_A_6','ses_A0001',1789000250000,1789000250000,'{"role":"assistant","mode":"compaction","agent":"compaction","summary":true,"time":{"created":1789000250000}}');
INSERT INTO part VALUES
 ('prt_A_1','msg_A_1','ses_A0001',1789000000000,1789000000000,'{"type":"text","text":"Hello, analyze the project"}'),
 ('prt_A_2','msg_A_2','ses_A0001',1789000100000,1789000100000,'{"type":"reasoning","text":"Let me think first."}'),
 ('prt_A_3','msg_A_2','ses_A0001',1789000100001,1789000100001,'{"type":"text","text":"I''ll look at the files."}'),
 ('prt_A_4','msg_A_2','ses_A0001',1789000100002,1789000100002,'{"type":"tool","tool":"read","state":{"status":"success","input":{"path":"src/a.py"},"output":"def hello(): pass"}}'),
 ('prt_A_5','msg_A_3','ses_A0001',1789000200000,1789000200000,'{"type":"compaction","auto":true,"tail_start_id":"msg_A_2"}'),
 ('prt_A_6','msg_A_3','ses_A0001',1789000200001,1789000200001,'{"type":"text","text":"Still working"}'),
 ('prt_A_7','msg_A_4','ses_A0001',1789000300000,1789000300000,'{"type":"text","text":"Done."}'),
 ('prt_A_8','msg_A_4','ses_A0001',1789000300001,1789000300001,'{"type":"step-start","tool":"plan"}'),
 ('prt_A_9','msg_A_5','ses_A0001',1789000400000,1789000400000,'{"type":"text","text":"Harmless boolean summary."}'),
 ('prt_A_10','msg_A_6','ses_A0001',1789000250000,1789000250000,'{"type":"text","text":"DIGEST_A: test compacted summary"}'),
 -- step-finish with real per-step usage (tokens/cost): source of the export-time backfill
 ('prt_A_11','msg_A_4','ses_A0001',1789000300002,1789000300002,'{"type":"step-finish","reason":"tool-calls","snapshot":"","tokens":{"total":1780,"input":1100,"output":600,"reasoning":80,"cache":{"read":50,"write":120}},"cost":0.05}'),
 -- tool with a fake API key to exercise --sanitize (output redacted at export time)
 ('prt_A_12','msg_A_3','ses_A0001',1789000200002,1789000200002,'{"type":"tool","tool":"bash","state":{"status":"success","input":{"command":"echo \$SECRET"},"output":"sk-test1234567890abcdefghijkl"}}');

-- Subagent A1
INSERT INTO message VALUES
 ('msg_A2_1','ses_A0002',1789000100000,1789000100000,'{"role":"user","time":{"created":1789000100000}}'),
 ('msg_A2_2','ses_A0002',1789000150000,1789000150000,'{"role":"assistant","time":{"created":1789000150000}}');
INSERT INTO part VALUES
 ('prt_A2_1','msg_A2_1','ses_A0002',1789000100000,1789000100000,'{"type":"text","text":"Explore the gaps"}'),
 ('prt_A2_2','msg_A2_2','ses_A0002',1789000150000,1789000150000,'{"type":"text","text":"Here is the report."}');

-- Root B (tool message with a long output to exercise truncation)
INSERT INTO message VALUES
 ('msg_B_1','ses_B0001',1789001000000,1789001000000,'{"role":"user","time":{"created":1789001000000}}'),
 ('msg_B_2','ses_B0001',1789001100000,1789001100000,'{"role":"assistant","time":{"created":1789001100000}}');
INSERT INTO part VALUES
 ('prt_B_1','msg_B_1','ses_B0001',1789001000000,1789001000000,'{"type":"text","text":"Run a search"}'),
 ('prt_B_2','msg_B_2','ses_B0001',1789001100000,1789001100000,'{"type":"tool","tool":"bash","state":{"status":"success","input":{"command":"grep -r algo ."},"output":"$LONG_OUTPUT"}}'),
 ('prt_B_3','msg_B_2','ses_B0001',1789001100001,1789001100001,'{"type":"text","text":"Done, I searched."}');

-- Subagent B1
INSERT INTO message VALUES
 ('msg_B2_1','ses_B0002',1789001100000,1789001100000,'{"role":"user","time":{"created":1789001100000}}');
INSERT INTO part VALUES
 ('prt_B2_1','msg_B2_1','ses_B0002',1789001100000,1789001100000,'{"type":"text","text":"Translate the docs"}');

-- Orphan subagent (its parent no longer exists): give it real content so the
-- shrink keep-set test can verify its transcript survives the prune.
INSERT INTO message VALUES
 ('msg_O_1','ses_ORPHAN01',1789002000000,1789002000000,'{"role":"user","time":{"created":1789002000000}}');
INSERT INTO part VALUES
 ('prt_O_1','msg_O_1','ses_ORPHAN01',1789002000000,1789002000000,'{"type":"text","text":"Report the status"}');

-- Auxiliary tables opencode also keeps: todo + the event store. Their rows must
-- be pruned by shrink too (session- and aggregate-bound) or they stay behind as
-- orphan references and the space is not reclaimed.
CREATE TABLE todo (
  session_id text NOT NULL,
  content text NOT NULL,
  status text NOT NULL,
  priority text NOT NULL,
  position integer,
  time_created integer NOT NULL,
  time_updated integer NOT NULL
);
CREATE TABLE event (
  id text PRIMARY KEY,
  aggregate_id text NOT NULL,
  seq integer NOT NULL,
  type text NOT NULL,
  data text NOT NULL
);
CREATE TABLE event_sequence (
  aggregate_id text NOT NULL,
  seq integer NOT NULL,
  owner_id text NOT NULL
);
INSERT INTO todo VALUES
 ('ses_A0001','implement helper','pending','high',1,1789000000000,1789000600000),
 ('ses_B0001','rename module','done','low',2,1789001000000,1789001600000),
 ('ses_B0001','add tests','pending','medium',3,1789001100000,1789001600000);
INSERT INTO event (id, aggregate_id, seq, type, data) VALUES
 ('evt_A_1','ses_A0001',1,'session.created.1','{"n":1}'),
 ('evt_A_2','ses_A0001',2,'session.updated.1','{"n":2}'),
 ('evt_A_3','ses_A0001',3,'message.updated.1','{"n":3}'),
 ('evt_B_1','ses_B0001',1,'session.created.1','{"n":1}'),
 ('evt_B_2','ses_B0001',2,'session.updated.1','{"n":2}'),
 ('evt_B_3','ses_B0001',3,'message.updated.1','{"n":3}'),
 ('evt_O_1','ses_ORPHAN01',1,'session.created.1','{"n":1}'),
 ('evt_O_2','ses_ORPHAN01',2,'session.updated.1','{"n":2}'),
 ('evt_O_3','ses_ORPHAN01',3,'message.updated.1','{"n":3}');
INSERT INTO event_sequence VALUES
 ('ses_A0001',3,''),('ses_B0001',3,''),('ses_ORPHAN01',3,'');

-- Remaining real tables (empty): the tool probes for them ('version' schema
-- check) and shrink prunes the session-bound ones.
CREATE TABLE session_share (session_id text PRIMARY KEY, id text NOT NULL, secret text NOT NULL, url text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL);
CREATE TABLE session_context_epoch (session_id text PRIMARY KEY, baseline text NOT NULL, snapshot text NOT NULL, baseline_seq integer NOT NULL);
CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
CREATE TABLE project (id text PRIMARY KEY, worktree text NOT NULL, vcs text, name text, time_created integer NOT NULL, time_updated integer NOT NULL, sandboxes text NOT NULL);
CREATE TABLE project_directory (project_id text NOT NULL, directory text NOT NULL, time_created integer NOT NULL, PRIMARY KEY(project_id, directory));
CREATE TABLE workspace (id text PRIMARY KEY, type text NOT NULL, name text DEFAULT '' NOT NULL, branch text, directory text, extra text, project_id text NOT NULL, time_used integer NOT NULL);
CREATE TABLE migration (id text PRIMARY KEY, time_completed integer NOT NULL);
CREATE TABLE data_migration (name text PRIMARY KEY, time_completed integer NOT NULL);
INSERT INTO migration VALUES ('20260101000000_test_migration', 1789000000000);
SQL

echo "[OK] Fake DB created: $DB"
echo "   sessions: $(sqlite3 "$DB" 'SELECT count(*) FROM session')  messages: $(sqlite3 "$DB" 'SELECT count(*) FROM message')  parts: $(sqlite3 "$DB" 'SELECT count(*) FROM part')"