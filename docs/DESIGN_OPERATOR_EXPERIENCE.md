# Orthanc Operator Experience Redesign

**Status:** Draft  
**Author:** Design Session  
**Date:** 2026-02-03  
**Version:** 1.0

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Goals & Non-Goals](#2-goals--non-goals)
3. [Architecture Overview](#3-architecture-overview)
4. [Component Specifications](#4-component-specifications)
5. [Data Models](#5-data-models)
6. [CLI Specification](#6-cli-specification)
7. [Configuration Formats](#7-configuration-formats)
8. [Logging Specification](#8-logging-specification)
9. [Metrics & Monitoring](#9-metrics--monitoring)
10. [Implementation Phases](#10-implementation-phases)
11. [Migration Plan](#11-migration-plan)
12. [Installation Workflow](#12-installation-workflow)
13. [Open Questions](#13-open-questions)

---

## 1. Problem Statement

### Current State

The Orthanc PACS system routes DICOM studies between:
- **Inbound:** CT/MR scanners send studies to Orthanc
- **AI Processing:** Bone length studies → MERCURE → AI results return
- **Outbound:** AI results → LPCHROUTER, LPCHTROUTER, MODLINK

**Operational challenges:**

| Problem | Impact |
|---------|--------|
| Configuration scattered across 5+ files | Hard to understand what's configured |
| Changes require container restarts | Downtime for config changes |
| Routing logic embedded in Lua code | Developers needed for routing changes |
| No visibility into routing state | Can't tell if studies are stuck/failed |
| No retry mechanism | Failed routes require manual intervention |
| Tribal knowledge required | New operators can't debug issues |
| No alerting | Failures discovered hours/days later |

### User Personas

**Primary: Clinical IT Operator**
- Responsible for keeping PACS running
- Limited programming experience
- Needs to add/remove DICOM destinations
- Needs to troubleshoot failed routing
- On-call for system issues

**Secondary: System Administrator**
- Manages infrastructure
- Handles upgrades and migrations
- Sets up monitoring/alerting

**Tertiary: Developer**
- Modifies routing logic
- Adds new features
- Debugs complex issues

---

## 2. Goals & Non-Goals

### Goals

1. **G1:** Operator can check system health with a single command
2. **G2:** Operator can add/remove DICOM destinations without code changes or restarts
3. **G3:** Operator can see which studies failed routing and retry them
4. **G4:** Operator can understand routing rules without reading Lua code
5. **G5:** System automatically retries failed routes with backoff
6. **G6:** Failed routes are visible in monitoring/alerting (Graphite/Grafana)
7. **G7:** All operations are logged with human-readable context
8. **G8:** System state persists across restarts (no lost routing state)

### Non-Goals

- **NG1:** High availability / clustering (single instance is acceptable)
- **NG2:** Web-based administration UI (CLI is sufficient for Phase 1)
- **NG3:** Multi-tenancy / user permissions
- **NG4:** Automated testing of routing rules
- **NG5:** DICOM query/retrieve management (focus is on routing)

---

## 3. Architecture Overview

### Current Architecture

```
┌─────────────┐     ┌─────────────────────────────────────────┐
│  Scanners   │────▶│              ORTHANC                    │
└─────────────┘     │  ┌─────────────────────────────────┐   │
                    │  │  Lua Script                      │   │
                    │  │  (autosend_leg_length.lua)       │   │
                    │  │  - Hardcoded routing logic       │   │
                    │  │  - No state tracking             │   │
                    │  │  - No retry logic                │   │
                    │  └─────────────────────────────────┘   │
                    │                                         │
                    │  ┌─────────────────────────────────┐   │
                    │  │  PostgreSQL                      │   │
                    │  │  - Study index only              │   │
                    │  └─────────────────────────────────┘   │
                    └──────────────┬──────────────────────────┘
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        ▼                          ▼                          ▼
   ┌─────────┐              ┌───────────┐              ┌─────────┐
   │ MERCURE │              │LPCHROUTER │              │ MODLINK │
   └─────────┘              └───────────┘              └─────────┘
```

### Target Architecture

```
┌─────────────┐     ┌─────────────────────────────────────────┐
│  Scanners   │────▶│              ORTHANC                    │
└─────────────┘     │                                         │
                    │  ┌─────────────────────────────────┐   │
       ┌───────────▶│  │  Route Engine                    │   │
       │            │  │  - Reads routes.yml              │   │
       │            │  │  - State tracking                │   │
       │            │  │  - Automatic retry               │   │
       │            │  │  - Structured logging            │   │
       │            │  └─────────────────────────────────┘   │
       │            │                                         │
       │            │  ┌─────────────────────────────────┐   │
       │            │  │  PostgreSQL                      │   │
       │            │  │  - Study index                   │   │
       │            │  │  - Routing state table           │   │
       │            │  │  - DICOM modalities (dynamic)    │   │
       │            │  └─────────────────────────────────┘   │
       │            └──────────────┬──────────────────────────┘
       │                           │
┌──────┴──────┐     ┌──────────────┼──────────────────────────┐
│ orthanc CLI │     │              │                          │
│             │     ▼              ▼                          ▼
│ - status    │ ┌─────────┐ ┌───────────┐              ┌─────────┐
│ - doctor    │ │ MERCURE │ │LPCHROUTER │              │ MODLINK │
│ - retry     │ └─────────┘ └───────────┘              └─────────┘
│ - logs      │
│ - ...       │        │
└─────────────┘        ▼
                  ┌─────────┐
                  │Graphite │───▶ Grafana
                  └─────────┘
```

### Component Interaction

```
┌────────────────────────────────────────────────────────────────┐
│                         OPERATOR                                │
│                            │                                    │
│         ┌──────────────────┼──────────────────────┐            │
│         ▼                  ▼                      ▼            │
│   ┌──────────┐      ┌──────────┐          ┌──────────┐        │
│   │ orthanc  │      │routes.yml│          │ Grafana  │        │
│   │   CLI    │      │  (edit)  │          │Dashboard │        │
│   └────┬─────┘      └────┬─────┘          └────┬─────┘        │
│        │                 │                      │              │
└────────┼─────────────────┼──────────────────────┼──────────────┘
         │                 │                      │
         ▼                 ▼                      ▼
┌────────────────────────────────────────────────────────────────┐
│                      ORTHANC SYSTEM                             │
│                                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐│
│  │  Orthanc    │  │  Route      │  │      PostgreSQL         ││
│  │  REST API   │◀─│  Engine     │──│  - routing_state        ││
│  │             │  │  (Lua)      │  │  - routing_config       ││
│  └──────┬──────┘  └──────┬──────┘  └─────────────────────────┘│
│         │                │                                     │
│         │                ▼                                     │
│         │         ┌─────────────┐                              │
│         └────────▶│  Graphite   │                              │
│                   │  (metrics)  │                              │
│                   └─────────────┘                              │
└────────────────────────────────────────────────────────────────┘
```

---

## 4. Component Specifications

### 4.1 CLI Tool (`orthanc`)

**Purpose:** Single entry point for all operator tasks.

**Technology:** Python 3.10+ with Click framework

**Installation:** `/usr/local/bin/orthanc` (symlink to `/opt/orthanc/cli/orthanc.py`)

**Dependencies:**
```
click>=8.0
requests>=2.28
rich>=13.0
psycopg2-binary>=2.9
python-dotenv>=1.0
pyyaml>=6.0
```

**Configuration:**
- Reads `/opt/orthanc/.env` for credentials and endpoints
- Falls back to environment variables

### 4.2 Route Engine

**Purpose:** Execute routing rules, track state, handle retries.

**Technology:** Lua (existing) with enhancements, or Python plugin (future)

**Capabilities:**
- Read routing rules from `routes.yml` or database
- Track routing state per study/destination in PostgreSQL
- Automatic retry with exponential backoff
- Emit structured logs
- Push metrics to Graphite

### 4.3 State Database

**Purpose:** Persist routing state across restarts.

**Technology:** PostgreSQL (existing instance, new tables)

**Tables:**
- `routing_state` - per-study routing status
- `routing_config` - cached routes (optional)
- `routing_metrics` - aggregated stats (optional)

### 4.4 Metrics Exporter

**Purpose:** Push routing metrics to Graphite.

**Technology:** 
- Option A: Lua HTTP to Graphite plaintext endpoint
- Option B: Log parsing with Vector/Telegraf
- Option C: Sidecar that reads routing_state and pushes metrics

**Metrics exported:**
- `orthanc.routing.{destination}.sent`
- `orthanc.routing.{destination}.success`
- `orthanc.routing.{destination}.failed`
- `orthanc.routing.{destination}.latency_ms`
- `orthanc.studies.pending`
- `orthanc.studies.stuck`

---

## 5. Data Models

### 5.1 Routing State Table

```sql
-- PostgreSQL schema for routing state tracking

CREATE TABLE routing_state (
    id                  SERIAL PRIMARY KEY,
    
    -- Study identification
    study_id            VARCHAR(64) NOT NULL,      -- Orthanc study ID
    study_uid           VARCHAR(128),              -- DICOM StudyInstanceUID
    patient_name        VARCHAR(256),
    patient_id          VARCHAR(64),
    study_description   VARCHAR(256),
    study_date          DATE,
    
    -- Routing target
    destination         VARCHAR(64) NOT NULL,      -- DICOM modality name
    route_name          VARCHAR(128),              -- Which route rule triggered this
    
    -- State tracking
    status              VARCHAR(20) NOT NULL,      -- see enum below
    
    -- Job tracking
    job_id              VARCHAR(64),               -- Orthanc job ID
    job_status          VARCHAR(20),               -- pending, running, success, failure
    
    -- Retry tracking
    attempt_count       INTEGER DEFAULT 0,
    max_attempts        INTEGER DEFAULT 3,
    next_retry_at       TIMESTAMP,
    
    -- Error tracking
    last_error          TEXT,
    last_error_at       TIMESTAMP,
    
    -- Timestamps
    created_at          TIMESTAMP DEFAULT NOW(),
    updated_at          TIMESTAMP DEFAULT NOW(),
    completed_at        TIMESTAMP,
    
    -- Constraints
    UNIQUE(study_id, destination)
);

-- Status enum values:
-- 'pending'    - Queued for routing, not yet attempted
-- 'sending'    - Currently being sent
-- 'sent'       - Sent, waiting for job completion
-- 'success'    - Successfully delivered
-- 'failed'     - Failed, will retry
-- 'stuck'      - Failed, max retries exceeded
-- 'skipped'    - Manually skipped by operator
-- 'cancelled'  - Routing cancelled

CREATE INDEX idx_routing_state_status ON routing_state(status);
CREATE INDEX idx_routing_state_study ON routing_state(study_id);
CREATE INDEX idx_routing_state_destination ON routing_state(destination);
CREATE INDEX idx_routing_state_next_retry ON routing_state(next_retry_at) 
    WHERE status = 'failed';
CREATE INDEX idx_routing_state_created ON routing_state(created_at);
```

### 5.2 Routing Configuration Table (Optional)

```sql
-- For storing routes in database instead of YAML file
-- Enables hot-reload without file watching

CREATE TABLE routing_config (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(128) NOT NULL UNIQUE,
    description     TEXT,
    enabled         BOOLEAN DEFAULT true,
    priority        INTEGER DEFAULT 100,        -- Lower = higher priority
    
    -- Match conditions (JSON)
    match_rules     JSONB NOT NULL,
    
    -- Action configuration (JSON)
    action          JSONB NOT NULL,
    
    -- Metadata
    created_at      TIMESTAMP DEFAULT NOW(),
    updated_at      TIMESTAMP DEFAULT NOW(),
    created_by      VARCHAR(64),
    
    -- Versioning
    version         INTEGER DEFAULT 1
);

-- Example match_rules:
-- {
--   "study_description": {"contains": "BONE LENGTH"},
--   "modality": {"equals": "CR"}
-- }

-- Example action:
-- {
--   "send": "highest_resolution",
--   "to": ["MERCURE"],
--   "retry": {"max_attempts": 3, "backoff": "exponential"}
-- }
```

### 5.3 Routing State Machine

```
                    ┌─────────────────────────────────────────┐
                    │                                         │
                    ▼                                         │
    ┌─────────┐  route   ┌─────────┐  send   ┌────────┐      │
    │ PENDING │────────▶│ SENDING │───────▶│  SENT  │      │
    └─────────┘          └────┬────┘         └───┬────┘      │
                              │                   │           │
                              │ error             │ job       │
                              │                   │ complete  │
                              ▼                   ▼           │
                         ┌─────────┐        ┌─────────┐      │
                         │ FAILED  │        │ SUCCESS │      │
                         └────┬────┘        └─────────┘      │
                              │                               │
              ┌───────────────┼───────────────┐              │
              │               │               │              │
              ▼               ▼               ▼              │
        ┌──────────┐   ┌───────────┐   ┌──────────┐         │
        │  retry   │   │   STUCK   │   │ SKIPPED  │         │
        │ (wait)   │   │(max retry)│   │ (manual) │         │
        └────┬─────┘   └───────────┘   └──────────┘         │
             │                                               │
             └───────────────────────────────────────────────┘
```

### 5.4 Configuration File Structure

```
/opt/orthanc/
├── .env                    # Credentials and endpoints
├── config/
│   ├── orthanc.json        # Orthanc core config (rarely changed)
│   └── routes.yml          # Routing rules (operator-editable)
├── cli/
│   ├── orthanc.py          # CLI entry point
│   └── requirements.txt
├── lua/
│   ├── route_engine.lua    # Main routing logic
│   └── lib/
│       ├── state.lua       # State tracking functions
│       ├── metrics.lua     # Graphite integration
│       └── logging.lua     # Structured logging
├── data/
│   ├── dicom/              # DICOM storage (bind mount)
│   └── postgres/           # PostgreSQL data (bind mount)
└── logs/                   # Application logs (optional)
```

---

## 6. CLI Specification

### 6.1 Command Overview

```
orthanc <command> [options]

COMMANDS:
  status              Show system status and health
  doctor              Run diagnostics and check connectivity
  logs                View and filter logs
  
  destinations        List configured DICOM destinations
  add-destination     Add a new DICOM destination (guided)
  remove-destination  Remove a DICOM destination
  test-destination    Test connectivity to a destination
  
  routes              List configured routing rules
  route-status        Show routing status for recent studies
  
  show-stuck          Show studies that failed routing
  show-pending        Show studies waiting to be routed
  retry               Retry routing for a study
  skip                Mark a study as skipped (won't retry)
  
  history             Show routing history for a study
  
  start               Start Orthanc services
  stop                Stop Orthanc services  
  restart             Restart Orthanc services
  
  backup              Create a backup
  restore             Restore from backup
  
  version             Show version information
  help                Show help for a command
```

### 6.2 Command Specifications

#### `orthanc status`

**Purpose:** Quick overview of system health.

**Output:**
```
🏥 ORTHANC STATUS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SERVICES                           STORAGE
  orthanc      ✅ running (3d)      DICOM:     2,340 studies (450 GB)
  postgres     ✅ running (3d)      Database:  12 GB
  ohif         ✅ running (3d)      Free:      550 GB

ROUTING (last 24 hours)
  📥 Received:    47 studies
  🤖 Sent to AI:  45 studies
  ✅ Completed:   43 studies
  ❌ Failed:      2 studies
  ⏳ Pending:     2 studies

DESTINATIONS
  MERCURE       ✅ reachable    last success: 5m ago
  LPCHROUTER    ✅ reachable    last success: 12m ago
  LPCHTROUTER   ✅ reachable    last success: 12m ago
  MODLINK       ⚠️  slow (2.3s)  last success: 1h ago

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
💡 2 studies need attention. Run 'orthanc show-stuck' for details.
```

**Options:**
- `--json` - Output as JSON
- `--quiet` - Only show issues

**Exit codes:**
- 0: All healthy
- 1: Warnings present
- 2: Errors present

---

#### `orthanc doctor`

**Purpose:** Run comprehensive diagnostics.

**Output:**
```
🩺 ORTHANC DIAGNOSTICS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

SERVICES
  ✅ Orthanc container running
  ✅ PostgreSQL container running
  ✅ OHIF container running
  ✅ Orthanc web UI responding (http://localhost:8042)
  ✅ DICOM port open (4242)

DATABASE
  ✅ PostgreSQL connection OK
  ✅ routing_state table exists
  ✅ Database size healthy (12 GB)

STORAGE
  ✅ DICOM storage writable (/opt/orthanc/data/dicom)
  ✅ PostgreSQL storage writable (/opt/orthanc/data/postgres)
  ⚠️  Disk 78% full (450 GB / 580 GB)

DESTINATIONS
  ✅ MERCURE (172.17.0.1:11112) - C-ECHO response: 45ms
  ✅ LPCHROUTER (10.50.133.21:4000) - C-ECHO response: 120ms
  ✅ LPCHTROUTER (10.50.130.114:4000) - C-ECHO response: 95ms
  ⚠️  MODLINK (10.251.201.59:104) - C-ECHO response: 2340ms (slow)

ROUTING
  ✅ routes.yml syntax valid
  ✅ 4 routes configured
  ⚠️  2 studies in 'stuck' state

LOGS
  ✅ No errors in last hour
  ⚠️  3 warnings in last hour

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SUMMARY: 2 warnings, 0 errors

RECOMMENDATIONS:
  1. Disk space: Consider cleaning old studies or expanding storage
  2. MODLINK: Check network connectivity, response time is high
  3. Stuck studies: Run 'orthanc show-stuck' to review
```

**Options:**
- `--fix` - Attempt to fix issues automatically
- `--json` - Output as JSON

---

#### `orthanc add-destination`

**Purpose:** Add a new DICOM destination with guided input.

**Interactive flow:**
```
🏥 ADD DICOM DESTINATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Enter a name for this destination (used in routing rules):
> STANFORD_PACS

Enter the AE Title (the destination's DICOM name):
> STANFORDPACS

Enter the IP address or hostname:
> 10.50.100.25

Enter the port [default: 104]:
> 4242

Testing connection to STANFORDPACS @ 10.50.100.25:4242...
✅ C-ECHO successful! Response time: 67ms

Configuration to add:
  Name:     STANFORD_PACS
  AE Title: STANFORDPACS
  Host:     10.50.100.25
  Port:     4242

Add this destination? [Y/n]: y

✅ Destination 'STANFORD_PACS' added successfully!

You can now use 'STANFORD_PACS' in routes.yml or with 'orthanc send'.
No restart required - destination is immediately available.
```

**Options:**
- `--name` - Destination name
- `--aet` - AE Title
- `--host` - IP address
- `--port` - Port number
- `--no-test` - Skip connectivity test
- `--yes` - Skip confirmation

---

#### `orthanc show-stuck`

**Purpose:** Show studies that failed routing and need attention.

**Output:**
```
⚠️  STUCK STUDIES (failed routing, need attention)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

ID          PATIENT          STUDY               DEST        FAILED    ERROR
──────────────────────────────────────────────────────────────────────────────
abc123def   DOE^JOHN         Leg Length         MERCURE     3x        Connection refused
789xyz456   SMITH^JANE       Leg Length         LPCHTROUTER 3x        Timeout (30s)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
2 studies stuck

ACTIONS:
  orthanc retry abc123def        Retry routing for this study
  orthanc retry --all            Retry all stuck studies
  orthanc skip abc123def         Mark as skipped (won't retry)
  orthanc history abc123def      View full routing history
```

**Options:**
- `--json` - Output as JSON
- `--destination` - Filter by destination
- `--since` - Filter by time (e.g., --since 24h)

---

#### `orthanc retry <study-id>`

**Purpose:** Retry routing for a failed/stuck study.

**Output:**
```
🔄 RETRYING ROUTING
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Study: abc123def
Patient: DOE^JOHN
Description: Bilateral Leg Length

Current state: STUCK (failed 3x to MERCURE)
Last error: Connection refused

Retrying send to MERCURE...
  ⏳ Sending...
  ✅ Sent! Job ID: job-789xyz

Routing state updated: STUCK → SENT

Monitor with: orthanc history abc123def
```

**Options:**
- `--all` - Retry all stuck studies
- `--destination` - Only retry for specific destination
- `--force` - Retry even if max attempts exceeded

---

#### `orthanc history <study-id>`

**Purpose:** Show complete routing timeline for a study.

**Output:**
```
📋 ROUTING HISTORY: abc123def
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

STUDY INFO
  Patient:     DOE^JOHN (MRN: 12345678)
  Study:       Bilateral Leg Length
  Date:        2026-02-03
  Images:      4 instances
  Study UID:   1.2.840.113619.2.55.3.123456789

TIMELINE
  2026-02-03 10:30:15  📥 RECEIVED
                       Source: CR_ROOM1 (10.50.100.10)
                       
  2026-02-03 10:30:16  🔍 MATCHED ROUTE
                       Rule: "Bone Length to AI"
                       Action: Send highest resolution to MERCURE
                       
  2026-02-03 10:30:17  📤 SENDING TO MERCURE
                       Job ID: job-123
                       
  2026-02-03 10:30:47  ❌ FAILED
                       Error: Connection refused
                       Retry scheduled: 10:31:17
                       
  2026-02-03 10:31:17  📤 RETRY 1: SENDING TO MERCURE
                       Job ID: job-124
                       
  2026-02-03 10:31:47  ❌ FAILED
                       Error: Connection refused
                       Retry scheduled: 10:33:17 (backoff: 2min)
                       
  2026-02-03 10:33:17  📤 RETRY 2: SENDING TO MERCURE
                       Job ID: job-125
                       
  2026-02-03 10:33:47  ❌ FAILED
                       Error: Connection refused
                       Status: STUCK (max retries exceeded)

CURRENT STATE
  MERCURE:      ❌ STUCK (3 attempts)
  LPCHROUTER:   ⏳ PENDING (waiting for AI results)
  LPCHTROUTER:  ⏳ PENDING (waiting for AI results)
  MODLINK:      ⏳ PENDING (waiting for AI results)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ACTIONS:
  orthanc retry abc123def        Retry failed routing
  orthanc skip abc123def         Mark as skipped
```

---

#### `orthanc logs`

**Purpose:** View and filter logs.

**Output:**
```
📋 ORTHANC LOGS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

10:45:23  INFO   [routing] Study received: SMITH^JANE, Leg Length (study-xyz)
10:45:24  INFO   [routing] Matched rule: "Bone Length to AI"
10:45:25  INFO   [routing] Sending to MERCURE (job-456)
10:45:55  INFO   [routing] MERCURE: Success (30s)
10:46:00  WARN   [routing] MODLINK: Slow response (2.1s)
10:47:12  INFO   [routing] AI results received for study-xyz
10:47:13  INFO   [routing] Routing AI results: QA → LPCHROUTER, LPCHTROUTER
10:47:14  INFO   [routing] Routing AI results: SR → MODLINK
10:47:45  INFO   [routing] All destinations confirmed for study-xyz

[Following... Press Ctrl+C to stop]
```

**Options:**
- `--follow, -f` - Follow log output (default)
- `--no-follow` - Show recent logs and exit
- `--errors` - Only show errors
- `--warnings` - Show warnings and errors
- `--since` - Show logs since time (e.g., --since 1h)
- `--study` - Filter by study ID
- `--grep` - Filter by pattern
- `--service` - Filter by service (orthanc, postgres, ohif)

---

## 7. Configuration Formats

### 7.1 Environment File (`.env`)

```bash
# /opt/orthanc/.env
# Orthanc Configuration - Credentials and Endpoints

# Orthanc API
ORTHANC_URL=http://localhost:8042
ORTHANC_USERNAME=orthanc_admin
ORTHANC_PASSWORD=your_secure_password_here

# PostgreSQL
POSTGRES_HOST=localhost
POSTGRES_PORT=5433
POSTGRES_DB=orthanc
POSTGRES_USER=orthanc
POSTGRES_PASSWORD=your_secure_password_here

# DICOM
ORTHANC_AET=ORTHANC_LPCH
ORTHANC_DICOM_PORT=4242

# Storage Paths
DICOM_STORAGE_PATH=/opt/orthanc/data/dicom
POSTGRES_DATA_PATH=/opt/orthanc/data/postgres

# Graphite Metrics (optional)
GRAPHITE_HOST=graphite.example.com
GRAPHITE_PORT=2003
GRAPHITE_PREFIX=orthanc.prod

# Alerting (optional)
ALERT_WEBHOOK_URL=https://hooks.slack.com/services/xxx
```

### 7.2 Routes Configuration (`routes.yml`)

```yaml
# /opt/orthanc/config/routes.yml
# 
# Routing Rules Configuration
# 
# This file defines where DICOM studies are automatically routed.
# Changes are detected automatically - no restart required.
#
# Format:
#   routes:
#     - name: Unique name for this route
#       description: Human-readable description
#       enabled: true/false
#       priority: Lower number = higher priority (default: 100)
#       
#       match:
#         <field>: <condition>
#         
#       action:
#         send: what to send (study, series, highest_resolution)
#         to: destination or list of destinations
#         
#       retry:
#         max_attempts: number of retries (default: 3)
#         backoff: constant, linear, or exponential (default: exponential)
#         initial_delay: seconds before first retry (default: 60)

routes:
  # ═══════════════════════════════════════════════════════════════
  # Route 1: Send bone length studies to AI for processing
  # ═══════════════════════════════════════════════════════════════
  - name: bone_length_to_ai
    description: Send leg length studies to MERCURE for AI measurement
    enabled: true
    priority: 10
    
    match:
      # Study description contains "BONE LENGTH" (case-insensitive)
      study_description:
        contains: "BONE LENGTH"
      # Only route if NOT already processed by AI
      manufacturer:
        not_equals: "STANFORDAIDE"
    
    action:
      # Send only the highest resolution image (not all images)
      send: highest_resolution
      to: MERCURE
    
    retry:
      max_attempts: 3
      backoff: exponential
      initial_delay: 60  # 1 minute, then 2 min, then 4 min

  # ═══════════════════════════════════════════════════════════════
  # Route 2: Send AI QA visualization images to PACS routers
  # ═══════════════════════════════════════════════════════════════
  - name: ai_qa_to_pacs
    description: Route AI QA visualization images to clinical PACS
    enabled: true
    priority: 20
    
    match:
      # Must be from Stanford AIDE
      manufacturer:
        equals: "STANFORDAIDE"
      # QA Visualization series (but not QA Table Visualization)
      series_description:
        contains: "QA Visualization"
        not_contains: "Table"
    
    action:
      send: instance  # Send the matched instance
      to:
        - LPCHROUTER
        - LPCHTROUTER
    
    retry:
      max_attempts: 3
      backoff: exponential
      initial_delay: 30

  # ═══════════════════════════════════════════════════════════════
  # Route 3: Send AI structured reports to MODLINK
  # ═══════════════════════════════════════════════════════════════
  - name: ai_sr_to_modlink
    description: Route AI structured reports to MODLINK
    enabled: true
    priority: 20
    
    match:
      manufacturer:
        equals: "STANFORDAIDE"
      modality:
        equals: "SR"
    
    action:
      send: instance
      to: MODLINK
    
    retry:
      max_attempts: 5  # More retries for important data
      backoff: exponential
      initial_delay: 60

# ═══════════════════════════════════════════════════════════════════
# Match Condition Reference
# ═══════════════════════════════════════════════════════════════════
#
# Available fields:
#   study_description    - DICOM StudyDescription tag
#   series_description   - DICOM SeriesDescription tag
#   modality            - DICOM Modality tag (CR, CT, MR, SR, etc.)
#   manufacturer        - DICOM Manufacturer tag
#   patient_name        - DICOM PatientName tag
#   patient_id          - DICOM PatientID tag
#   institution_name    - DICOM InstitutionName tag
#   station_name        - DICOM StationName tag
#   source_aet          - AE Title of the sender
#
# Condition types:
#   equals: "value"           - Exact match (case-insensitive)
#   not_equals: "value"       - Does not equal
#   contains: "value"         - Contains substring
#   not_contains: "value"     - Does not contain substring
#   starts_with: "value"      - Starts with
#   ends_with: "value"        - Ends with
#   matches: "regex"          - Regular expression match
#   in: ["a", "b", "c"]       - Value is one of
#   not_in: ["a", "b"]        - Value is not one of
#
# Multiple conditions in match: ALL must be true (AND logic)
# For OR logic, create separate routes with same action
```

### 7.3 Orthanc Core Configuration (`orthanc.json`)

Changes from current config:

```json
{
  // ... existing settings ...
  
  // CHANGED: Enable database storage of modalities (allows hot-reload)
  "DicomModalitiesInDatabase": true,
  
  // CHANGED: Load all Lua files from directory
  "LuaScripts": ["/etc/orthanc/lua/"],
  
  // ADDED: Enable Python plugin (for future route engine)
  "PythonScript": "/etc/orthanc/python/route_engine.py",
  
  // ... rest of config unchanged ...
}
```

---

## 8. Logging Specification

### 8.1 Log Format

**Structured log format for machine parsing:**

```
TIMESTAMP LEVEL [COMPONENT] EVENT_TYPE KEY=VALUE KEY=VALUE ...
```

**Examples:**

```
2026-02-03T10:30:15Z INFO  [routing] study_received study_id=abc123 patient=DOE^JOHN description="Leg Length" instances=4
2026-02-03T10:30:16Z INFO  [routing] route_matched study_id=abc123 route=bone_length_to_ai action=send_to_mercure
2026-02-03T10:30:17Z INFO  [routing] send_started study_id=abc123 destination=MERCURE job_id=job-123
2026-02-03T10:30:47Z ERROR [routing] send_failed study_id=abc123 destination=MERCURE error="Connection refused" attempt=1 max_attempts=3 next_retry=2026-02-03T10:31:47Z
2026-02-03T10:31:47Z INFO  [routing] send_started study_id=abc123 destination=MERCURE job_id=job-124 attempt=2
2026-02-03T10:32:17Z INFO  [routing] send_success study_id=abc123 destination=MERCURE job_id=job-124 duration_ms=30000
```

### 8.2 Event Types

| Event | Level | Description |
|-------|-------|-------------|
| `study_received` | INFO | New study arrived |
| `route_matched` | INFO | Study matched a routing rule |
| `route_no_match` | DEBUG | Study didn't match any routes |
| `send_started` | INFO | Started sending to destination |
| `send_success` | INFO | Successfully sent |
| `send_failed` | ERROR | Send failed |
| `send_retry_scheduled` | WARN | Retry scheduled |
| `study_stuck` | ERROR | Max retries exceeded |
| `destination_unreachable` | ERROR | C-ECHO failed |
| `destination_slow` | WARN | C-ECHO slow (>1s) |
| `config_reloaded` | INFO | Routes config reloaded |

### 8.3 Human-Readable Log Mode

For terminal viewing, format logs as:

```
10:30:15  📥 RECEIVED    DOE^JOHN - Leg Length (4 images)
10:30:16  🔍 MATCHED     Route: "Bone Length to AI" → MERCURE
10:30:17  📤 SENDING     → MERCURE (job-123)
10:30:47  ❌ FAILED      MERCURE: Connection refused (retry in 60s)
10:31:47  📤 RETRY 1     → MERCURE (job-124)
10:32:17  ✅ SUCCESS     MERCURE: Delivered (30s)
```

---

## 9. Metrics & Monitoring

### 9.1 Metrics to Export

**Counters (increment on each event):**
```
orthanc.routing.received              # Studies received
orthanc.routing.matched               # Studies matched a route
orthanc.routing.sent{dest=X}          # Sent to destination X
orthanc.routing.success{dest=X}       # Successfully delivered
orthanc.routing.failed{dest=X}        # Failed (will retry)
orthanc.routing.stuck{dest=X}         # Max retries exceeded
orthanc.routing.skipped{dest=X}       # Manually skipped
```

**Gauges (current value):**
```
orthanc.studies.total                 # Total studies in system
orthanc.studies.pending               # Studies pending routing
orthanc.studies.stuck                 # Studies in stuck state
orthanc.storage.size_gb               # Storage used
orthanc.storage.free_gb               # Storage free
orthanc.destinations.up{dest=X}       # 1 if reachable, 0 if not
```

**Timers (latency tracking):**
```
orthanc.routing.latency_ms{dest=X}    # Time to deliver to destination
orthanc.destinations.echo_ms{dest=X}  # C-ECHO response time
```

### 9.2 Graphite Integration

**Push metrics from Lua:**

```lua
function pushMetric(name, value, timestamp)
    local graphite_host = os.getenv("GRAPHITE_HOST") or "localhost"
    local graphite_port = os.getenv("GRAPHITE_PORT") or 2003
    local prefix = os.getenv("GRAPHITE_PREFIX") or "orthanc"
    
    local metric_line = string.format("%s.%s %s %d\n", 
        prefix, name, value, timestamp or os.time())
    
    -- Log for collection by external agent (simplest approach)
    print("METRIC " .. metric_line)
end

-- Usage:
pushMetric("routing.sent.mercure", 1)
pushMetric("routing.latency_ms.mercure", 30000)
```

**Alternative: Telegraf sidecar:**

```toml
# telegraf.conf
[[inputs.tail]]
  files = ["/var/log/orthanc/*.log"]
  from_beginning = false
  data_format = "grok"
  grok_patterns = ['METRIC %{NOTSPACE:measurement} %{NUMBER:value:float}']

[[outputs.graphite]]
  servers = ["${GRAPHITE_HOST}:${GRAPHITE_PORT}"]
  prefix = "${GRAPHITE_PREFIX}"
```

### 9.3 Grafana Dashboard

**Dashboard panels:**

1. **Overview Stats** (stat panels)
   - Studies received (24h)
   - Routing success rate
   - Currently pending
   - Currently stuck

2. **Routing Volume** (time series)
   - `orthanc.routing.received` vs `orthanc.routing.success`
   - Grouped by destination

3. **Destination Health** (gauge/traffic light)
   - Status of each destination
   - Response time

4. **Latency** (time series)
   - p50, p95, p99 routing latency per destination

5. **Failures** (table)
   - Recent failures with study ID, destination, error

6. **Storage** (gauge)
   - Disk usage with thresholds

### 9.4 Alerting Rules

```yaml
# Grafana alerting rules

- name: Orthanc Alerts
  rules:
    - alert: OrthancDown
      expr: up{job="orthanc"} == 0
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "Orthanc is down"
    
    - alert: RoutingFailureSpike
      expr: rate(orthanc.routing.failed[5m]) > 0.1
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Routing failures increasing"
    
    - alert: StudiesStuck
      expr: orthanc.studies.stuck > 5
      for: 30m
      labels:
        severity: warning
      annotations:
        summary: "{{ $value }} studies stuck in routing"
    
    - alert: DestinationDown
      expr: orthanc.destinations.up == 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Destination {{ $labels.dest }} unreachable"
    
    - alert: DiskSpaceLow
      expr: orthanc.storage.free_gb < 50
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "Disk space below 50GB"
```

---

## 10. Implementation Phases

### Phase 1: Foundation (Week 1)

**Goal:** Enable core infrastructure changes, no new features yet.

**Tasks:**

1. **Enable `DicomModalitiesInDatabase: true`**
   - Update `orthanc.json`
   - Test that existing modalities still work
   - Verify destinations can be added via API

2. **Create PostgreSQL schema**
   - Add `routing_state` table
   - Test with manual inserts

3. **Create `.env` file**
   - Consolidate credentials
   - Remove hardcoded values from configs

4. **Restructure directories**
   - Create `/opt/orthanc/config/`
   - Create `/opt/orthanc/cli/`
   - Move files to new structure

**Deliverables:**
- [ ] Updated `orthanc.json` with database modalities
- [ ] PostgreSQL migration script
- [ ] `.env` file template
- [ ] Directory structure created

---

### Phase 2: CLI Core (Week 2)

**Goal:** Basic CLI with status and diagnostics.

**Tasks:**

1. **Create CLI skeleton**
   - Python project setup
   - Click command structure
   - Configuration loading from `.env`

2. **Implement `orthanc status`**
   - Query Docker for service status
   - Query Orthanc API for stats
   - Query PostgreSQL for routing state
   - Pretty print with Rich

3. **Implement `orthanc doctor`**
   - Service health checks
   - Database connectivity
   - Storage checks
   - Destination C-ECHO tests

4. **Implement `orthanc logs`**
   - Wrapper around `docker compose logs`
   - Filtering options

**Deliverables:**
- [ ] Working CLI with `status`, `doctor`, `logs` commands
- [ ] Installation script
- [ ] CLI documentation

---

### Phase 3: Destination Management (Week 2-3)

**Goal:** Add/remove destinations without editing files.

**Tasks:**

1. **Implement `orthanc destinations`**
   - List all configured destinations
   - Show last success time

2. **Implement `orthanc add-destination`**
   - Guided interactive flow
   - C-ECHO test before adding
   - Uses Orthanc REST API

3. **Implement `orthanc remove-destination`**
   - Confirmation prompt
   - Check if used in routes

4. **Implement `orthanc test-destination`**
   - C-ECHO test with timing

**Deliverables:**
- [ ] Destination management commands working
- [ ] No restart required for changes

---

### Phase 4: State Tracking (Week 3-4)

**Goal:** Track routing state, enable retry/skip.

**Tasks:**

1. **Update Lua script**
   - Write routing state to PostgreSQL
   - Structured logging
   - Read state before routing

2. **Implement `orthanc show-stuck`**
   - Query routing_state for stuck studies
   - Formatted output

3. **Implement `orthanc show-pending`**
   - Query routing_state for pending studies

4. **Implement `orthanc retry`**
   - Reset state to pending
   - Trigger re-routing via API

5. **Implement `orthanc skip`**
   - Mark study as skipped
   - Record reason

6. **Implement `orthanc history`**
   - Show full timeline for a study

**Deliverables:**
- [ ] Lua script with state tracking
- [ ] Retry/skip workflow working
- [ ] History command working

---

### Phase 5: Automatic Retry (Week 4)

**Goal:** System automatically retries failed routes.

**Tasks:**

1. **Implement retry scheduler**
   - Background process or cron
   - Query for failed studies due for retry
   - Exponential backoff

2. **Implement stuck detection**
   - Identify studies exceeding max retries
   - Update state to stuck

3. **Implement job completion tracking**
   - Use Orthanc's job callbacks
   - Update routing state on success/failure

**Deliverables:**
- [ ] Automatic retry working
- [ ] Job completion updates state

---

### Phase 6: Declarative Routes (Week 5-6)

**Goal:** Routes defined in YAML, not Lua code.

**Tasks:**

1. **Design route matching engine**
   - Parse YAML conditions
   - Evaluate against DICOM tags

2. **Implement YAML parser in Lua or Python**
   - Load routes.yml
   - Validate syntax

3. **Implement hot-reload**
   - Watch for file changes
   - Reload without restart

4. **Migrate existing Lua logic to YAML**
   - Create routes.yml with current rules
   - Test equivalence

5. **Implement `orthanc routes`**
   - List configured routes
   - Show match statistics

6. **Implement `orthanc route-status`**
   - Show which routes are matching
   - Recent matches

**Deliverables:**
- [ ] routes.yml working
- [ ] Hot-reload working
- [ ] Existing routing migrated

---

### Phase 7: Metrics & Dashboard (Week 6-7)

**Goal:** Visibility in Grafana via Graphite.

**Tasks:**

1. **Add metrics to Lua/Python**
   - Push metrics on each event
   - Counters, gauges, timers

2. **Configure Graphite collection**
   - Telegraf or log parsing
   - Verify metrics arriving

3. **Create Grafana dashboard**
   - Overview stats
   - Routing volume
   - Destination health
   - Failures table

4. **Configure alerting**
   - Define alert rules
   - Set up notification channel

**Deliverables:**
- [ ] Metrics flowing to Graphite
- [ ] Grafana dashboard
- [ ] Alerting configured

---

## 11. Migration Plan

### 11.1 Pre-Migration Checklist

- [ ] Full backup created (`orthanc-manager.sh backup`)
- [ ] Current state documented
- [ ] Downtime window scheduled (if needed)
- [ ] Rollback plan tested

### 11.2 Migration Steps

**Step 1: Database Migration (no downtime)**

```bash
# Connect to PostgreSQL and create new tables
psql -h localhost -p 5433 -U orthanc -d orthanc < migrations/001_routing_state.sql
```

**Step 2: Enable Database Modalities (requires restart)**

```bash
# Update orthanc.json
sed -i 's/"DicomModalitiesInDatabase": false/"DicomModalitiesInDatabase": true/' /opt/orthanc/orthanc.json

# Restart
docker compose restart orthanc
```

**Step 3: Deploy CLI (no downtime)**

```bash
# Install CLI
pip install -r /opt/orthanc/cli/requirements.txt
ln -s /opt/orthanc/cli/orthanc.py /usr/local/bin/orthanc

# Test
orthanc status
```

**Step 4: Deploy New Lua Script (requires restart)**

```bash
# Backup existing
cp /opt/orthanc/lua-scripts/autosend_leg_length.lua /opt/orthanc/lua-scripts/autosend_leg_length.lua.backup

# Deploy new
cp lua/route_engine.lua /opt/orthanc/lua-scripts/

# Restart
docker compose restart orthanc
```

**Step 5: Migrate Routes to YAML (after Phase 6)**

```bash
# Create routes.yml from existing Lua logic
# (Manual process, verify each route)

# Test with both systems running in parallel
# Then disable old Lua script
```

### 11.3 Rollback Plan

```bash
# If issues arise, rollback to previous state:

# Restore Lua script
cp /opt/orthanc/lua-scripts/autosend_leg_length.lua.backup /opt/orthanc/lua-scripts/autosend_leg_length.lua

# Disable database modalities
sed -i 's/"DicomModalitiesInDatabase": true/"DicomModalitiesInDatabase": false/' /opt/orthanc/orthanc.json

# Restart
docker compose restart orthanc

# Routing state table can remain (doesn't affect old behavior)
```

---

## 12. Installation Workflow

### 12.1 Repository Structure

```
orthanc/
├── README.md                    # Quick start guide
├── install.sh                   # Interactive installer
├── Makefile                     # Common operations
│
├── docker-compose.yml           # Service definitions
├── docker-compose.override.yml  # Local overrides (gitignored)
│
├── config/
│   ├── orthanc.json            # Orthanc core config
│   ├── routes.yml              # Routing rules
│   ├── nginx.conf              # OHIF proxy config
│   └── .env.template           # Environment template
│
├── cli/
│   ├── orthanc.py              # CLI entry point
│   ├── requirements.txt        # Python dependencies
│   └── lib/
│       ├── api.py              # Orthanc API client
│       ├── db.py               # Database operations
│       └── display.py          # Output formatting
│
├── lua/
│   ├── route_engine.lua        # Main routing logic
│   └── lib/
│       ├── state.lua           # State tracking
│       ├── metrics.lua         # Graphite integration
│       └── logging.lua         # Structured logging
│
├── migrations/
│   └── 001_routing_state.sql   # Database schema
│
├── grafana/
│   └── dashboards/
│       └── orthanc.json        # Grafana dashboard
│
├── docs/
│   ├── DESIGN_OPERATOR_EXPERIENCE.md
│   ├── INSTALLATION.md         # Detailed install guide
│   ├── OPERATIONS.md           # Day-to-day operations
│   ├── TROUBLESHOOTING.md      # Common issues
│   └── CHANGELOG.md            # Version history
│
└── tests/
    └── ...                     # Test files (future)
```

### 12.2 Prerequisites

| Requirement | Minimum Version | Check Command |
|-------------|-----------------|---------------|
| Docker | 20.10+ | `docker --version` |
| Docker Compose | 2.0+ (V2) | `docker compose version` |
| Python | 3.10+ | `python3 --version` |
| Git | 2.0+ | `git --version` |
| curl | any | `curl --version` |

**System Requirements:**
- RAM: 4GB minimum, 8GB recommended
- Disk: 50GB minimum for system, plus storage for DICOM data
- Ports: 8042, 8008, 4242, 5433 available

### 12.3 Installation Methods

#### Method 1: Interactive Installer (Recommended)

```bash
# Clone the repository
git clone https://github.com/your-org/orthanc.git
cd orthanc

# Run interactive installer
./install.sh
```

The installer guides through:
1. Prerequisites check
2. Configuration (passwords, paths, AE title)
3. Directory creation
4. Service startup
5. Health verification

#### Method 2: Quick Install (Non-Interactive)

```bash
git clone https://github.com/your-org/orthanc.git
cd orthanc

# Set required environment variables
export ORTHANC_PASSWORD="your_secure_password"
export POSTGRES_PASSWORD="your_db_password"
export DICOM_STORAGE_PATH="/data/orthanc/dicom"
export POSTGRES_DATA_PATH="/data/orthanc/postgres"

# Run non-interactive install
./install.sh --non-interactive
```

#### Method 3: Manual Installation

See [Detailed Manual Steps](#124-detailed-installation-steps) below.

### 12.4 Detailed Installation Steps

#### Step 1: Clone Repository

```bash
# Clone to a working directory
cd /opt
sudo git clone https://github.com/your-org/orthanc.git
cd orthanc

# Set ownership (if not running as root)
sudo chown -R $USER:$USER /opt/orthanc
```

#### Step 2: Create Configuration

```bash
# Copy environment template
cp config/.env.template .env

# Edit configuration
nano .env
```

**Required settings to change:**
```bash
# .env - MUST CHANGE THESE
ORTHANC_PASSWORD=your_secure_password_here
POSTGRES_PASSWORD=your_secure_password_here

# Change these if using non-default paths
DICOM_STORAGE_PATH=/opt/orthanc/data/dicom
POSTGRES_DATA_PATH=/opt/orthanc/data/postgres

# Change this to your site's AE title
ORTHANC_AET=YOUR_AET_HERE
```

#### Step 3: Create Data Directories

```bash
# Source the environment
source .env

# Create directories
sudo mkdir -p "$DICOM_STORAGE_PATH"
sudo mkdir -p "$POSTGRES_DATA_PATH"

# Set permissions
# DICOM storage: Orthanc runs as UID 1000 in container
sudo chown -R 1000:1000 "$DICOM_STORAGE_PATH"

# PostgreSQL: runs as UID 999 in container  
sudo chown -R 999:999 "$POSTGRES_DATA_PATH"
```

#### Step 4: Generate Configuration Files

```bash
# Generate orthanc.json with passwords substituted
./scripts/generate-config.sh

# Or manually: substitute passwords in config files
envsubst < config/orthanc.json.template > config/orthanc.json
```

#### Step 5: Start Services

```bash
# Pull images
docker compose pull

# Start services
docker compose up -d

# Wait for services to initialize
sleep 15

# Check status
docker compose ps
```

#### Step 6: Initialize Database

```bash
# Run migrations
docker compose exec orthanc-db psql -U orthanc -d orthanc \
  -f /migrations/001_routing_state.sql

# Or use the CLI (after installing it)
orthanc db-migrate
```

#### Step 7: Install CLI

```bash
# Create virtual environment (optional but recommended)
python3 -m venv /opt/orthanc/venv
source /opt/orthanc/venv/bin/activate

# Install dependencies
pip install -r cli/requirements.txt

# Create symlink for global access
sudo ln -sf /opt/orthanc/cli/orthanc.py /usr/local/bin/orthanc

# Or add to PATH
echo 'export PATH="/opt/orthanc/cli:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Verify
orthanc --version
```

#### Step 8: Verify Installation

```bash
# Run diagnostics
orthanc doctor

# Expected output:
# 🩺 ORTHANC DIAGNOSTICS
# ━━━━━━━━━━━━━━━━━━━━━━
# ✅ Orthanc container running
# ✅ PostgreSQL container running
# ✅ OHIF container running
# ✅ Database connection OK
# ✅ Storage accessible
# ...
```

#### Step 9: Configure DICOM Destinations

```bash
# Add your DICOM destinations
orthanc add-destination

# Or import from existing config
orthanc import-destinations /path/to/old/orthanc.json
```

#### Step 10: Configure Routing Rules

```bash
# Edit routing rules
nano config/routes.yml

# Validate syntax
orthanc routes --validate

# View configured routes
orthanc routes
```

### 12.5 Install Script Specification

```bash
#!/usr/bin/env bash
# install.sh - Orthanc Installation Script

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
DEFAULT_INSTALL_DIR="/opt/orthanc"
DEFAULT_DICOM_PATH="/opt/orthanc/data/dicom"
DEFAULT_POSTGRES_PATH="/opt/orthanc/data/postgres"
DEFAULT_AET="ORTHANC"
DEFAULT_DICOM_PORT="4242"
DEFAULT_WEB_PORT="8042"
DEFAULT_VIEWER_PORT="8008"

# Flags
NON_INTERACTIVE=false
SKIP_DOCKER_CHECK=false
UPGRADE_MODE=false

#═══════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
#═══════════════════════════════════════════════════════════════

log_info() { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✓${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
log_error() { echo -e "${RED}✗${NC} $1"; }

print_banner() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                                                           ║"
    echo "║   🏥  ORTHANC PACS INSTALLATION                          ║"
    echo "║                                                           ║"
    echo "║   Version: $VERSION                                       ║"
    echo "║                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

prompt() {
    local prompt_text="$1"
    local default_value="${2:-}"
    local var_name="$3"
    
    if [[ -n "$default_value" ]]; then
        read -p "$prompt_text [$default_value]: " input
        eval "$var_name=\"${input:-$default_value}\""
    else
        read -p "$prompt_text: " input
        eval "$var_name=\"$input\""
    fi
}

prompt_password() {
    local prompt_text="$1"
    local var_name="$2"
    
    read -sp "$prompt_text: " input
    echo
    eval "$var_name=\"$input\""
}

confirm() {
    local prompt_text="$1"
    local default="${2:-n}"
    
    if [[ "$default" == "y" ]]; then
        read -p "$prompt_text [Y/n]: " response
        [[ -z "$response" || "$response" =~ ^[Yy] ]]
    else
        read -p "$prompt_text [y/N]: " response
        [[ "$response" =~ ^[Yy] ]]
    fi
}

check_command() {
    command -v "$1" &> /dev/null
}

generate_password() {
    openssl rand -base64 24 | tr -d '/+=' | head -c 24
}

#═══════════════════════════════════════════════════════════════
# PREREQUISITE CHECKS
#═══════════════════════════════════════════════════════════════

check_prerequisites() {
    log_info "Checking prerequisites..."
    local errors=0
    
    # Docker
    if check_command docker; then
        local docker_version=$(docker --version | grep -oP '\d+\.\d+' | head -1)
        log_success "Docker $docker_version"
    else
        log_error "Docker not found"
        ((errors++))
    fi
    
    # Docker Compose V2
    if docker compose version &> /dev/null; then
        local compose_version=$(docker compose version --short)
        log_success "Docker Compose $compose_version"
    else
        log_error "Docker Compose V2 not found"
        ((errors++))
    fi
    
    # Python
    if check_command python3; then
        local python_version=$(python3 --version | grep -oP '\d+\.\d+')
        log_success "Python $python_version"
    else
        log_error "Python 3 not found"
        ((errors++))
    fi
    
    # Git
    if check_command git; then
        log_success "Git installed"
    else
        log_warning "Git not found (optional)"
    fi
    
    # Check if Docker daemon is running
    if docker info &> /dev/null; then
        log_success "Docker daemon running"
    else
        log_error "Docker daemon not running"
        ((errors++))
    fi
    
    if [[ $errors -gt 0 ]]; then
        log_error "Prerequisites check failed. Please install missing components."
        exit 1
    fi
    
    log_success "All prerequisites satisfied"
}

check_ports() {
    log_info "Checking port availability..."
    local ports=("$WEB_PORT" "$VIEWER_PORT" "$DICOM_PORT" "5433")
    
    for port in "${ports[@]}"; do
        if ss -tuln | grep -q ":$port "; then
            log_error "Port $port is already in use"
            return 1
        else
            log_success "Port $port available"
        fi
    done
}

#═══════════════════════════════════════════════════════════════
# CONFIGURATION
#═══════════════════════════════════════════════════════════════

collect_configuration() {
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  CONFIGURATION${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo
    
    # Installation directory
    prompt "Installation directory" "$DEFAULT_INSTALL_DIR" INSTALL_DIR
    
    # Storage paths
    echo
    log_info "Storage Configuration"
    prompt "DICOM storage path" "$DEFAULT_DICOM_PATH" DICOM_STORAGE_PATH
    prompt "PostgreSQL data path" "$DEFAULT_POSTGRES_PATH" POSTGRES_DATA_PATH
    
    # DICOM settings
    echo
    log_info "DICOM Configuration"
    prompt "DICOM AE Title" "$DEFAULT_AET" ORTHANC_AET
    prompt "DICOM port" "$DEFAULT_DICOM_PORT" DICOM_PORT
    
    # Web ports
    echo
    log_info "Web Ports"
    prompt "Orthanc web port" "$DEFAULT_WEB_PORT" WEB_PORT
    prompt "OHIF viewer port" "$DEFAULT_VIEWER_PORT" VIEWER_PORT
    
    # Credentials
    echo
    log_info "Credentials"
    
    if [[ "$NON_INTERACTIVE" == true ]] && [[ -n "${ORTHANC_PASSWORD:-}" ]]; then
        log_info "Using ORTHANC_PASSWORD from environment"
    else
        echo "Enter password for Orthanc admin user (or press Enter to generate):"
        prompt_password "Orthanc admin password" ORTHANC_PASSWORD
        if [[ -z "$ORTHANC_PASSWORD" ]]; then
            ORTHANC_PASSWORD=$(generate_password)
            log_info "Generated password: $ORTHANC_PASSWORD"
            echo "⚠️  Save this password! It will be stored in .env"
        fi
    fi
    
    if [[ "$NON_INTERACTIVE" == true ]] && [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
        log_info "Using POSTGRES_PASSWORD from environment"
    else
        echo "Enter PostgreSQL password (or press Enter to generate):"
        prompt_password "PostgreSQL password" POSTGRES_PASSWORD
        if [[ -z "$POSTGRES_PASSWORD" ]]; then
            POSTGRES_PASSWORD=$(generate_password)
            log_info "Generated password (saved in .env)"
        fi
    fi
    
    # Summary
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  CONFIGURATION SUMMARY${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo
    echo "  Installation:   $INSTALL_DIR"
    echo "  DICOM Storage:  $DICOM_STORAGE_PATH"
    echo "  Database:       $POSTGRES_DATA_PATH"
    echo "  AE Title:       $ORTHANC_AET"
    echo "  DICOM Port:     $DICOM_PORT"
    echo "  Web UI:         http://localhost:$WEB_PORT"
    echo "  OHIF Viewer:    http://localhost:$VIEWER_PORT"
    echo
    
    if ! confirm "Proceed with installation?" "y"; then
        log_info "Installation cancelled"
        exit 0
    fi
}

#═══════════════════════════════════════════════════════════════
# INSTALLATION
#═══════════════════════════════════════════════════════════════

create_directories() {
    log_info "Creating directories..."
    
    sudo mkdir -p "$DICOM_STORAGE_PATH"
    sudo mkdir -p "$POSTGRES_DATA_PATH"
    sudo mkdir -p "$INSTALL_DIR/logs"
    
    # Set ownership
    sudo chown -R 1000:1000 "$DICOM_STORAGE_PATH"
    sudo chown -R 999:999 "$POSTGRES_DATA_PATH"
    
    log_success "Directories created"
}

create_env_file() {
    log_info "Creating .env file..."
    
    cat > "$INSTALL_DIR/.env" << EOF
# Orthanc Configuration
# Generated by install.sh on $(date)

# Orthanc API
ORTHANC_URL=http://localhost:$WEB_PORT
ORTHANC_USERNAME=orthanc_admin
ORTHANC_PASSWORD=$ORTHANC_PASSWORD

# PostgreSQL
POSTGRES_HOST=localhost
POSTGRES_PORT=5433
POSTGRES_DB=orthanc
POSTGRES_USER=orthanc
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# DICOM
ORTHANC_AET=$ORTHANC_AET
ORTHANC_DICOM_PORT=$DICOM_PORT

# Storage
DICOM_STORAGE_PATH=$DICOM_STORAGE_PATH
POSTGRES_DATA_PATH=$POSTGRES_DATA_PATH

# Web Ports
ORTHANC_WEB_PORT=$WEB_PORT
OHIF_PORT=$VIEWER_PORT
EOF

    chmod 600 "$INSTALL_DIR/.env"
    log_success ".env file created"
}

generate_configs() {
    log_info "Generating configuration files..."
    
    # Substitute variables in orthanc.json
    export ORTHANC_PASSWORD POSTGRES_PASSWORD ORTHANC_AET
    envsubst < "$INSTALL_DIR/config/orthanc.json.template" > "$INSTALL_DIR/config/orthanc.json"
    
    # Update docker-compose.yml with paths
    # (or use docker-compose.override.yml)
    cat > "$INSTALL_DIR/docker-compose.override.yml" << EOF
# Local overrides - generated by install.sh
version: '3.1'

services:
  orthanc:
    ports:
      - "$WEB_PORT:8042"
      - "$DICOM_PORT:4242"
  
  ohif:
    ports:
      - "$VIEWER_PORT:80"

volumes:
  orthanc-storage:
    driver: local
    driver_opts:
      type: 'none'
      o: 'bind'
      device: '$DICOM_STORAGE_PATH'
  
  orthanc-db-data:
    driver: local
    driver_opts:
      type: 'none'
      o: 'bind'
      device: '$POSTGRES_DATA_PATH'
EOF

    log_success "Configuration files generated"
}

start_services() {
    log_info "Starting services..."
    
    cd "$INSTALL_DIR"
    
    # Pull images
    docker compose pull
    
    # Start services
    docker compose up -d
    
    log_success "Services started"
}

wait_for_services() {
    log_info "Waiting for services to be ready..."
    
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$WEB_PORT" | grep -q "200\|302\|401"; then
            log_success "Orthanc is ready"
            return 0
        fi
        
        ((attempt++))
        echo -n "."
        sleep 2
    done
    
    log_error "Timeout waiting for Orthanc"
    return 1
}

run_migrations() {
    log_info "Running database migrations..."
    
    cd "$INSTALL_DIR"
    
    # Wait for PostgreSQL
    sleep 5
    
    # Run migrations
    docker compose exec -T orthanc-db psql -U orthanc -d orthanc \
        < migrations/001_routing_state.sql
    
    log_success "Migrations complete"
}

install_cli() {
    log_info "Installing CLI..."
    
    # Create virtual environment
    python3 -m venv "$INSTALL_DIR/venv"
    
    # Install dependencies
    "$INSTALL_DIR/venv/bin/pip" install -q -r "$INSTALL_DIR/cli/requirements.txt"
    
    # Create wrapper script
    cat > "$INSTALL_DIR/orthanc" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/.env" 2>/dev/null || true
source "$SCRIPT_DIR/venv/bin/activate"
exec python3 "$SCRIPT_DIR/cli/orthanc.py" "$@"
EOF
    chmod +x "$INSTALL_DIR/orthanc"
    
    # Create symlink
    sudo ln -sf "$INSTALL_DIR/orthanc" /usr/local/bin/orthanc
    
    log_success "CLI installed"
}

verify_installation() {
    echo
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  VERIFYING INSTALLATION${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo
    
    local errors=0
    
    # Check containers
    if docker compose -f "$INSTALL_DIR/docker-compose.yml" ps | grep -q "running"; then
        log_success "Containers running"
    else
        log_error "Containers not running"
        ((errors++))
    fi
    
    # Check Orthanc API
    if curl -s -u "orthanc_admin:$ORTHANC_PASSWORD" "http://localhost:$WEB_PORT/system" | grep -q "Version"; then
        log_success "Orthanc API responding"
    else
        log_error "Orthanc API not responding"
        ((errors++))
    fi
    
    # Check OHIF
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$VIEWER_PORT" | grep -q "200"; then
        log_success "OHIF viewer responding"
    else
        log_warning "OHIF viewer not responding (may still be starting)"
    fi
    
    # Check CLI
    if /usr/local/bin/orthanc --version &> /dev/null; then
        log_success "CLI installed"
    else
        log_error "CLI not working"
        ((errors++))
    fi
    
    return $errors
}

print_completion() {
    echo
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                           ║${NC}"
    echo -e "${GREEN}║   ✅  INSTALLATION COMPLETE                               ║${NC}"
    echo -e "${GREEN}║                                                           ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BLUE}Access your system:${NC}"
    echo
    echo "  Orthanc Web UI:  http://localhost:$WEB_PORT"
    echo "  OHIF Viewer:     http://localhost:$VIEWER_PORT"
    echo "  DICOM Port:      $DICOM_PORT (AET: $ORTHANC_AET)"
    echo
    echo -e "${BLUE}Credentials:${NC}"
    echo
    echo "  Username:  orthanc_admin"
    echo "  Password:  $ORTHANC_PASSWORD"
    echo
    echo -e "${BLUE}Quick commands:${NC}"
    echo
    echo "  orthanc status     - Check system status"
    echo "  orthanc doctor     - Run diagnostics"
    echo "  orthanc logs       - View logs"
    echo "  orthanc help       - Show all commands"
    echo
    echo -e "${YELLOW}⚠️  Save your credentials! They are stored in:${NC}"
    echo "  $INSTALL_DIR/.env"
    echo
}

#═══════════════════════════════════════════════════════════════
# MAIN
#═══════════════════════════════════════════════════════════════

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --upgrade)
                UPGRADE_MODE=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [options]"
                echo
                echo "Options:"
                echo "  --non-interactive  Run without prompts (requires env vars)"
                echo "  --upgrade          Upgrade existing installation"
                echo "  --help             Show this help"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    print_banner
    check_prerequisites
    
    if [[ "$NON_INTERACTIVE" == true ]]; then
        # Use environment variables or defaults
        INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
        DICOM_STORAGE_PATH="${DICOM_STORAGE_PATH:-$DEFAULT_DICOM_PATH}"
        POSTGRES_DATA_PATH="${POSTGRES_DATA_PATH:-$DEFAULT_POSTGRES_PATH}"
        ORTHANC_AET="${ORTHANC_AET:-$DEFAULT_AET}"
        DICOM_PORT="${DICOM_PORT:-$DEFAULT_DICOM_PORT}"
        WEB_PORT="${WEB_PORT:-$DEFAULT_WEB_PORT}"
        VIEWER_PORT="${VIEWER_PORT:-$DEFAULT_VIEWER_PORT}"
        ORTHANC_PASSWORD="${ORTHANC_PASSWORD:-$(generate_password)}"
        POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(generate_password)}"
    else
        collect_configuration
    fi
    
    check_ports
    create_directories
    create_env_file
    generate_configs
    start_services
    wait_for_services
    run_migrations
    install_cli
    
    if verify_installation; then
        print_completion
    else
        log_error "Installation completed with errors. Check logs for details."
        exit 1
    fi
}

main "$@"
```

### 12.6 Makefile for Common Operations

```makefile
# Makefile - Common Orthanc operations

.PHONY: help install start stop restart logs status clean upgrade backup

# Default target
help:
	@echo "Orthanc Management Commands"
	@echo ""
	@echo "  make install    - Run installation"
	@echo "  make start      - Start services"
	@echo "  make stop       - Stop services"
	@echo "  make restart    - Restart services"
	@echo "  make logs       - View logs (follow mode)"
	@echo "  make status     - Show status"
	@echo "  make backup     - Create backup"
	@echo "  make upgrade    - Upgrade to latest"
	@echo "  make clean      - Remove containers (keep data)"
	@echo ""

# Installation
install:
	@./install.sh

# Service management
start:
	@docker compose up -d
	@echo "Services started. Run 'orthanc status' to verify."

stop:
	@docker compose stop
	@echo "Services stopped."

restart:
	@docker compose restart
	@echo "Services restarted."

logs:
	@docker compose logs -f

status:
	@orthanc status

# Maintenance
backup:
	@orthanc backup

upgrade:
	@echo "Pulling latest changes..."
	@git pull
	@echo "Pulling latest images..."
	@docker compose pull
	@echo "Restarting services..."
	@docker compose up -d
	@echo "Running migrations..."
	@orthanc db-migrate
	@echo "Upgrade complete."

clean:
	@docker compose down
	@echo "Containers removed. Data preserved."

# Development
dev-logs:
	@docker compose logs -f orthanc

dev-shell:
	@docker compose exec orthanc /bin/bash

dev-db:
	@docker compose exec orthanc-db psql -U orthanc -d orthanc
```

### 12.7 Upgrade Workflow

```bash
#!/usr/bin/env bash
# upgrade.sh - Upgrade Orthanc to latest version

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "🔄 ORTHANC UPGRADE"
echo "════════════════════════════════════════"

# Check for uncommitted changes
if [[ -n $(git status -s) ]]; then
    echo "⚠️  You have local changes. Please commit or stash them first."
    git status -s
    exit 1
fi

# Backup current state
echo "📦 Creating backup..."
orthanc backup --quiet

# Pull latest code
echo "📥 Pulling latest changes..."
git fetch origin
git pull origin main

# Check for breaking changes
if [[ -f UPGRADE_NOTES.md ]]; then
    echo ""
    echo "📋 Upgrade notes:"
    cat UPGRADE_NOTES.md
    echo ""
    read -p "Continue with upgrade? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Upgrade cancelled."
        exit 0
    fi
fi

# Pull new images
echo "🐳 Pulling new Docker images..."
docker compose pull

# Stop services
echo "⏹️  Stopping services..."
docker compose stop

# Run migrations
echo "🗄️  Running database migrations..."
docker compose up -d orthanc-db
sleep 5
for migration in migrations/*.sql; do
    if [[ -f "$migration" ]]; then
        echo "  Applying: $migration"
        docker compose exec -T orthanc-db psql -U orthanc -d orthanc < "$migration" 2>/dev/null || true
    fi
done

# Start services
echo "▶️  Starting services..."
docker compose up -d

# Verify
echo "✅ Verifying..."
sleep 10
orthanc doctor --quiet

echo ""
echo "════════════════════════════════════════"
echo "✅ Upgrade complete!"
echo ""
echo "Run 'orthanc status' to verify."
```

### 12.8 Uninstallation

```bash
#!/usr/bin/env bash
# uninstall.sh - Remove Orthanc installation

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/orthanc}"

echo "🗑️  ORTHANC UNINSTALLATION"
echo "════════════════════════════════════════"
echo ""
echo "This will remove:"
echo "  • Docker containers and images"
echo "  • CLI tool"
echo "  • Configuration files"
echo ""
echo "This will NOT remove:"
echo "  • DICOM data (in configured storage path)"
echo "  • PostgreSQL data (in configured data path)"
echo ""

read -p "Are you sure you want to uninstall? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Uninstallation cancelled."
    exit 0
fi

# Source config for paths
source "$INSTALL_DIR/.env" 2>/dev/null || true

echo "Stopping containers..."
docker compose -f "$INSTALL_DIR/docker-compose.yml" down --rmi all 2>/dev/null || true

echo "Removing CLI..."
sudo rm -f /usr/local/bin/orthanc

echo "Removing configuration..."
rm -rf "$INSTALL_DIR/venv"
rm -f "$INSTALL_DIR/.env"
rm -f "$INSTALL_DIR/docker-compose.override.yml"

echo ""
echo "════════════════════════════════════════"
echo "✅ Uninstallation complete."
echo ""
echo "Data preserved in:"
echo "  DICOM:     ${DICOM_STORAGE_PATH:-/opt/orthanc/data/dicom}"
echo "  Database:  ${POSTGRES_DATA_PATH:-/opt/orthanc/data/postgres}"
echo ""
echo "To completely remove all data:"
echo "  sudo rm -rf ${DICOM_STORAGE_PATH:-/opt/orthanc/data/dicom}"
echo "  sudo rm -rf ${POSTGRES_DATA_PATH:-/opt/orthanc/data/postgres}"
echo ""
```

---

## 13. Open Questions

### 13.1 Technical Decisions Needed

1. **Route Engine: Lua vs Python Plugin?**
   - Lua: Familiar, already in use, limited capabilities
   - Python: More powerful, native YAML support, but different codebase
   - **Recommendation:** Start with Lua enhancements, migrate to Python in Phase 6+

2. **State Tracking: Metadata vs Database Table?**
   - Metadata: Simple, built into Orthanc
   - Database table: More flexible, queryable
   - **Recommendation:** Database table for full tracking

3. **Metrics Collection: Push vs Log Parsing?**
   - Push (Lua → Graphite): Direct, real-time
   - Log parsing (Telegraf): Simpler Lua, flexible
   - **Recommendation:** Log parsing with Telegraf (simpler)

4. **Hot-Reload: File watching vs API?**
   - File watching: Simple, filesystem-based
   - API: More controlled, audit trail
   - **Recommendation:** File watching for Phase 1, add API later

### 13.2 Operational Questions

1. **What is the SLA for routing?**
   - How long can a study wait before it's "stuck"?
   - What's the maximum acceptable latency?

2. **Who receives alerts?**
   - Email? Slack? PagerDuty?
   - What hours? (24/7 vs business hours)

3. **Retention policy for routing_state?**
   - How long to keep history?
   - Archive or delete old records?

4. **Testing environment?**
   - Is there a staging system?
   - How to test changes safely?

### 13.3 Future Considerations

1. **High Availability:** Could add read replica for PostgreSQL, load balancer for Orthanc
2. **Multi-site:** Could extend to route between sites
3. **Audit logging:** Could add detailed access logging for compliance
4. **Web UI:** Could add browser-based dashboard for non-CLI users

---

## Appendix A: File Templates

### A.1 PostgreSQL Migration Script

```sql
-- migrations/001_routing_state.sql

BEGIN;

CREATE TABLE IF NOT EXISTS routing_state (
    id                  SERIAL PRIMARY KEY,
    study_id            VARCHAR(64) NOT NULL,
    study_uid           VARCHAR(128),
    patient_name        VARCHAR(256),
    patient_id          VARCHAR(64),
    study_description   VARCHAR(256),
    study_date          DATE,
    destination         VARCHAR(64) NOT NULL,
    route_name          VARCHAR(128),
    status              VARCHAR(20) NOT NULL DEFAULT 'pending',
    job_id              VARCHAR(64),
    job_status          VARCHAR(20),
    attempt_count       INTEGER DEFAULT 0,
    max_attempts        INTEGER DEFAULT 3,
    next_retry_at       TIMESTAMP,
    last_error          TEXT,
    last_error_at       TIMESTAMP,
    created_at          TIMESTAMP DEFAULT NOW(),
    updated_at          TIMESTAMP DEFAULT NOW(),
    completed_at        TIMESTAMP,
    UNIQUE(study_id, destination)
);

CREATE INDEX IF NOT EXISTS idx_routing_state_status ON routing_state(status);
CREATE INDEX IF NOT EXISTS idx_routing_state_study ON routing_state(study_id);
CREATE INDEX IF NOT EXISTS idx_routing_state_destination ON routing_state(destination);
CREATE INDEX IF NOT EXISTS idx_routing_state_next_retry ON routing_state(next_retry_at) WHERE status = 'failed';
CREATE INDEX IF NOT EXISTS idx_routing_state_created ON routing_state(created_at);

COMMIT;
```

### A.2 Environment File Template

```bash
# /opt/orthanc/.env.template
# Copy to .env and fill in values

# Orthanc API
ORTHANC_URL=http://localhost:8042
ORTHANC_USERNAME=orthanc_admin
ORTHANC_PASSWORD=CHANGE_ME

# PostgreSQL
POSTGRES_HOST=localhost
POSTGRES_PORT=5433
POSTGRES_DB=orthanc
POSTGRES_USER=orthanc
POSTGRES_PASSWORD=CHANGE_ME

# DICOM
ORTHANC_AET=ORTHANC_LPCH
ORTHANC_DICOM_PORT=4242

# Storage
DICOM_STORAGE_PATH=/opt/orthanc/data/dicom
POSTGRES_DATA_PATH=/opt/orthanc/data/postgres

# Graphite (optional)
# GRAPHITE_HOST=graphite.example.com
# GRAPHITE_PORT=2003
# GRAPHITE_PREFIX=orthanc.prod
```

---

## Appendix B: Glossary

| Term | Definition |
|------|------------|
| **AE Title** | Application Entity Title - DICOM's identifier for a system |
| **C-ECHO** | DICOM command to test connectivity |
| **C-STORE** | DICOM command to send images |
| **Modality** | Type of imaging equipment (CR, CT, MR, etc.) |
| **PACS** | Picture Archiving and Communication System |
| **Route** | A rule that matches studies and sends them somewhere |
| **Stuck** | A study that failed routing and exceeded retry attempts |

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-02-03 | Design Session | Initial draft |
| 1.1 | 2026-02-03 | Design Session | Added Section 12: Installation Workflow |