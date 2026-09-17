#!/usr/bin/env bash
# make_fake_db.sh — creates a small fake opencode DB for tests.
# Usage: make_fake_db.sh <output.db>
# Schema mirrors the real tables used by the tool (session, message, part).
set -euo pipefail

DB="${1:?Uso: make_fake_db.sh <output.db>}"
rm -f "$DB"

# Long tool output (>500 chars, single line for valid JSON) to exercise truncation.
LONG_OUTPUT="$(printf 'palabra_repeticion_%s ' {1..110})"

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

-- Raíz A con subagentes
INSERT INTO session VALUES
 ('ses_A0001','proj1','alfa-alpha','/tmp/projA','Proyecto Alfa','1.0',NULL,NULL,'build','{"id":"model-a","providerID":"opencode"}',
  0,1000,500,0,0,0,1789000000000,1789000600000,NULL,NULL),
 ('ses_A0002','proj1','gaps','/tmp/projA','Explorar gaps (@explore subagent)','1.0',NULL,'ses_A0001','explore','{"id":"model-b","providerID":"opencode"}',
  0,200,30,0,0,0,1789000100000,1789000200000,NULL,NULL),
 ('ses_A0003','proj1','bugs','/tmp/projA','Find false bugs (@explore subagent)','1.0',NULL,'ses_A0001','explore','{"id":"model-b","providerID":"opencode"}',
  0,300,40,0,0,0,1789000300000,1789000400000,NULL,NULL);
-- Raíz B con un subagente y una huérfana (padre inexistente)
INSERT INTO session VALUES
 ('ses_B0001','proj2','beta-bravo','/tmp/projB','Proyecto Beta','1.0',NULL,NULL,'build','{"id":"model-a","providerID":"opencode"}',
  0,500,90,0,0,0,1789001000000,1789001600000,NULL,NULL),
 ('ses_B0002','proj2','beta-sub','/tmp/projB','Traducir docs (@explore subagent)','1.0',NULL,'ses_B0001','explore','{"id":"model-b","providerID":"opencode"}',
  0,50,10,0,0,0,1789001100000,1789001200000,NULL,NULL),
 ('ses_ORPHAN01','proj3','orphan','/tmp/projC','Subagente huérfano (@explore subagent)','1.0',NULL,'ses_DESAPARECIDA','explore','{"id":"model-b","providerID":"opencode"}',
  0,10,5,0,0,0,1789002000000,1789002100000,NULL,NULL);

-- Mensajes de la raíz A (con compactación y summary.diffs)
INSERT INTO message VALUES
 ('msg_A_1','ses_A0001',1789000000000,1789000000000,'{"role":"user","time":{"created":1789000000000},"agent":"build"}'),
 ('msg_A_2','ses_A0001',1789000100000,1789000100000,'{"role":"assistant","time":{"created":1789000100000},"agent":"build"}'),
 ('msg_A_3','ses_A0001',1789000200000,1789000200000,'{"role":"user","time":{"created":1789000200000},"summary":{"diffs":[{"file":"src/a.py","patch":"...","additions":5,"deletions":2,"status":"modified"}]}}'),
 ('msg_A_4','ses_A0001',1789000300000,1789000300000,'{"role":"assistant","time":{"created":1789000300000},"agent":"build"}');
INSERT INTO part VALUES
 ('prt_A_1','msg_A_1','ses_A0001',1789000000000,1789000000000,'{"type":"text","text":"Hola, analiza el proyecto"}'),
 ('prt_A_2','msg_A_2','ses_A0001',1789000100000,1789000100000,'{"type":"reasoning","text":"Primero pienso"}'),
 ('prt_A_3','msg_A_2','ses_A0001',1789000100001,1789000100001,'{"type":"text","text":"Voy a mirar los archivos."}'),
 ('prt_A_4','msg_A_2','ses_A0001',1789000100002,1789000100002,'{"type":"tool","tool":"read","state":{"status":"success","input":{"path":"src/a.py"},"output":"def hola(): pass"}}'),
 ('prt_A_5','msg_A_3','ses_A0001',1789000200000,1789000200000,'{"type":"compaction","auto":true,"tail_start_id":"msg_A_2"}'),
 ('prt_A_6','msg_A_3','ses_A0001',1789000200001,1789000200001,'{"type":"text","text":"Sigo trabajando"}'),
 ('prt_A_7','msg_A_4','ses_A0001',1789000300000,1789000300000,'{"type":"text","text":"Hecho."}'),
 ('prt_A_8','msg_A_4','ses_A0001',1789000300001,1789000300001,'{"type":"step-start","tool":"plan"}');

-- Subagente A1
INSERT INTO message VALUES
 ('msg_A2_1','ses_A0002',1789000100000,1789000100000,'{"role":"user","time":{"created":1789000100000}}'),
 ('msg_A2_2','ses_A0002',1789000150000,1789000150000,'{"role":"assistant","time":{"created":1789000150000}}');
INSERT INTO part VALUES
 ('prt_A2_1','msg_A2_1','ses_A0002',1789000100000,1789000100000,'{"type":"text","text":"Explora los gaps"}'),
 ('prt_A2_2','msg_A2_2','ses_A0002',1789000150000,1789000150000,'{"type":"text","text":"Aqui esta el informe."}');

-- Raíz B (mensaje con tool y output largo para probar truncado)
INSERT INTO message VALUES
 ('msg_B_1','ses_B0001',1789001000000,1789001000000,'{"role":"user","time":{"created":1789001000000}}'),
 ('msg_B_2','ses_B0001',1789001100000,1789001100000,'{"role":"assistant","time":{"created":1789001100000}}');
INSERT INTO part VALUES
 ('prt_B_1','msg_B_1','ses_B0001',1789001000000,1789001000000,'{"type":"text","text":"Haz una busqueda"}'),
 ('prt_B_2','msg_B_2','ses_B0001',1789001100000,1789001100000,'{"type":"tool","tool":"bash","state":{"status":"success","input":{"command":"grep -r algo ."},"output":"$LONG_OUTPUT"}}'),
 ('prt_B_3','msg_B_2','ses_B0001',1789001100001,1789001100001,'{"type":"text","text":"Listo, busqué."}');

-- Subagente B1
INSERT INTO message VALUES
 ('msg_B2_1','ses_B0002',1789001100000,1789001100000,'{"role":"user","time":{"created":1789001100000}}');
INSERT INTO part VALUES
 ('prt_B2_1','msg_B2_1','ses_B0002',1789001100000,1789001100000,'{"type":"text","text":"Traduce los docs"}');
SQL

echo "✅ DB falsa creada: $DB"
echo "   sesiones: $(sqlite3 "$DB" 'SELECT count(*) FROM session')  mensajes: $(sqlite3 "$DB" 'SELECT count(*) FROM message')  partes: $(sqlite3 "$DB" 'SELECT count(*) FROM part')"