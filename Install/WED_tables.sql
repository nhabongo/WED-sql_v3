--multiples instance of a particular wedflow

DROP TABLE IF EXISTS WED_attr;
DROP TABLE IF EXISTS WED_trace;
DROP TABLE IF EXISTS JOB_POOL;
DROP TABLE IF EXISTS WED_trig;
DROP TABLE IF EXISTS ST_STATUS;
DROP SEQUENCE IF EXISTS widseq;

CREATE SEQUENCE widseq;

-- An '*' means that WED-attributes columns will be added dynamicaly after an INSERT on WED-attr table
--*WED-flow instances

CREATE TABLE WED_attr (
    aname    TEXT NOT NULL,
    adv   TEXT,
    enabled BOOL NOT NULL DEFAULT TRUE
);
-- name must be unique 
CREATE UNIQUE INDEX wed_attr_lower_name_idx ON WED_attr (lower(aname));

--Fast final WED-state detection(Running,Final,Exception)
CREATE TABLE ST_STATUS (
    wid     INTEGER PRIMARY KEY,
    status  TEXT NOT NULL DEFAULT 'R'
);

CREATE TABLE WED_trig (
    tgid     SERIAL PRIMARY KEY,
    tgname  TEXT NOT NULL DEFAULT '',
    enabled BOOL NOT NULL DEFAULT TRUE,
    trname  TEXT NOT NULL,
    cname  TEXT NOT NULL DEFAULT '',
    cpred  TEXT NOT NULL DEFAULT '',
    cfinal BOOL NOT NULL DEFAULT FALSE,
    timeout    INTERVAL DEFAULT '00:01:00'
);
CREATE UNIQUE INDEX wed_trig_lower_trname_idx ON WED_trig (lower(trname));
CREATE UNIQUE INDEX wed_trig_cfinal_idx ON WED_trig (cfinal) WHERE cfinal is TRUE;


--Running transitions
CREATE TABLE JOB_POOL (
    wid     INTEGER NOT NULL ,
    tgid    INTEGER NOT NULL,
    trname   TEXT NOT NULL,
    lckid   TEXT,
    timeout    INTERVAL NOT NULL,
    payload JSON NOT NULL,
    PRIMARY KEY (wid,tgid),
    FOREIGN KEY (wid) REFERENCES ST_STATUS (wid) ON DELETE RESTRICT,
    FOREIGN KEY (tgid) REFERENCES WED_trig (tgid) ON DELETE RESTRICT
);     

--*WED-trace keeps the execution history for all instances
CREATE TABLE WED_trace (
    wid     INTEGER,
    trw    TEXT DEFAULT NULL,
    trf    TEXT[] DEFAULT NULL,
    status    TEXT NOT NULL DEFAULT 'R',
    tstmp      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    state      JSON NOT NULL,
    FOREIGN KEY (wid) REFERENCES ST_STATUS (wid) ON DELETE RESTRICT
);
