-- ═══════════════════════════════════════════════════════════════════════════════
-- RADWATCH ROUTING - CONFIGURATION
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- PURPOSE:
--   Central configuration for all routing logic. 
--   Change settings here, not scattered throughout code.
--
-- HOW ORTHANC LOADS THIS:
--   This file is loaded by main.lua using: dofile('/path/to/config.lua')
--   It returns a table that main.lua stores as `Config`
--
-- ═══════════════════════════════════════════════════════════════════════════════

local Config = {}

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 1: API ENDPOINTS
-- ─────────────────────────────────────────────────────────────────────────────────
-- These are the URLs the Lua script calls to track routing state.
-- The routing-api service runs inside Docker Compose.

Config.API = {
    -- Base URL for the routing tracking API
    -- Inside Docker: containers can reach each other by service name
    -- 
    -- TODO: Verify this URL works from inside the orthanc container
    --       Test: docker exec orthanc-server curl http://routing-api:5000/health
    --
    BASE_URL = "http://routing-api:5000",
    
    -- Specific endpoints (built from BASE_URL)
    -- These are defined here so you can see what's available
    ENDPOINTS = {
        HEALTH      = "/health",           -- GET  - Check if API is up
        TRACK_START = "/track/start",      -- POST - Record study received
        TRACK_SEND  = "/track/destination",-- POST - Record send attempt
        TRACK_AI    = "/track/ai-results", -- POST - Record AI results received
    },
    
    -- Timeout for API calls (seconds)
    -- If the API doesn't respond in this time, we continue anyway
    TIMEOUT_SECONDS = 5,
}

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 2: DESTINATIONS
-- ─────────────────────────────────────────────────────────────────────────────────
-- DICOM modalities this system routes to.
-- These must match the names configured in Orthanc (via UI or API).
--
-- NOTE: The actual connection details (AET, Host, Port) are stored in Orthanc,
--       not here. This is just the symbolic name used in SendToModality().

Config.DESTINATIONS = {
    -- AI Processing
    MERCURE = "MERCURE",           -- Sends to MERCURE for AI analysis
    
    -- Final PACS destinations (after AI processing)
    LPCH    = "LPCHROUTER",        -- LPCH PACS
    LPCHT   = "LPCHTROUTER",       -- LPCHT PACS  
    MODLINK = "MODLINK",           -- Structured reports
}

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 3: STUDY MATCHING RULES
-- ─────────────────────────────────────────────────────────────────────────────────
-- Patterns to identify which studies should be routed.
-- Uses Lua patterns (similar to regex but simpler).
--
-- Lua pattern quick reference:
--   .  = any character
--   %s = whitespace
--   %d = digit
--   *  = zero or more
--   +  = one or more
--   -  = zero or more (non-greedy)
--   ?  = optional (zero or one)
--   ^  = start of string
--   $  = end of string
--
-- For case-insensitive matching, we convert to uppercase first.

Config.MATCHING = {
    -- Studies that should go through AI pipeline
    -- Note: Include both space and underscore versions for flexibility
    BONE_LENGTH_PATTERNS = {
        "EXTREMITY BILATERAL BONE LENGTH",    -- With spaces
        "EXTREMITY_BILATERAL_BONE_LENGTH",    -- With underscores (LPCH format)
        "BONE LENGTH",                        -- Shorter fallback
    },
    
    -- Patterns to identify AI results coming back from MERCURE
    -- If ANY series matches ANY of these, it's considered AI_RESULT
    AI_RESULT_PATTERNS = {
        "AI MEASUREMENTS",      -- AI output measurements
        "QA VISUALIZATION",     -- QA overlay images
        "STANFORDAIDE",         -- Legacy: some systems may use this
    },
    
    -- Pattern for QA Visualization (route to LPCH/LPCHT)
    QA_MEASUREMENTS_PATTERN = "AI MEASUREMENTS",
    QA_VIZ_PATTERN = "QA VISUALIZATION",
    QA_VIZ_EXCLUDE = "TABLE",             -- Exclude if also contains this
    
    --
    -- TODO [TASK 1]: Review these patterns
    --
    -- Questions to answer:
    -- 1. Are there other study descriptions that should trigger routing?
    -- 2. Is "STANFORD AIDE" the exact string in SeriesDescription?
    -- 3. Are there edge cases these patterns miss?
    --
    -- To find examples, run in psql:
    --   SELECT DISTINCT "StudyDescription" FROM studies ORDER BY 1;
    --
}

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 4: RETRY & TIMING
-- ─────────────────────────────────────────────────────────────────────────────────
-- Settings for error handling and retries.
-- 
-- NOTE: Current implementation doesn't have automatic retries.
--       These are here for when we add that feature.

Config.RETRY = {
    -- How many times to retry a failed send
    MAX_ATTEMPTS = 3,
    
    -- Seconds between retries (will be multiplied: 60, 120, 240)
    INITIAL_DELAY_SECONDS = 300,
    
    -- Multiplier for exponential backoff
    BACKOFF_MULTIPLIER = 2,
    
    --
    -- TODO [TASK 2]: Decide on retry strategy
    --
    -- Questions to answer:
    -- 1. Should failed sends retry automatically, or just log?
    -- 2. What's an acceptable delay before alerting someone?
    -- 3. Should different destinations have different retry policies?
    --
}

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 5: LOGGING
-- ─────────────────────────────────────────────────────────────────────────────────
-- Control what gets logged and how.

Config.LOGGING = {
    -- Prefix for all log messages (makes it easy to grep)
    PREFIX = "[RADWATCH]",
    
    -- Log levels: ERROR, WARN, INFO, DEBUG
    -- Set to DEBUG during development, INFO in production
    LEVEL = "DEBUG",
    
    -- Include timestamps? (Orthanc already adds timestamps, so maybe not needed)
    INCLUDE_TIMESTAMP = false,
    
    -- Log full DICOM tags? (verbose but helpful for debugging)
    LOG_FULL_TAGS = false,
}

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 6: FEATURE FLAGS  
-- ─────────────────────────────────────────────────────────────────────────────────
-- Toggle features on/off without changing code.

Config.FEATURES = {
    -- Master switch: if false, no routing happens (for maintenance)
    ROUTING_ENABLED = true,
    
    -- Track workflows in database?
    TRACKING_ENABLED = true,
    
    -- Send to AI (MERCURE)?
    AI_PROCESSING_ENABLED = true,
    
    -- Send to final destinations (LPCH, LPCHT, MODLINK)?
    FINAL_ROUTING_ENABLED = true,
    
    --
    -- TODO [TASK 3]: Consider what flags you need
    --
    -- Questions to answer:
    -- 1. Should you be able to disable individual destinations?
    -- 2. Do you need a "dry run" mode that logs but doesn't send?
    -- 3. What should happen if TRACKING_ENABLED is false?
    --
}

-- ─────────────────────────────────────────────────────────────────────────────────
-- RETURN THE CONFIG TABLE
-- ─────────────────────────────────────────────────────────────────────────────────
-- This makes the Config table available to other files that load this one.

return Config
