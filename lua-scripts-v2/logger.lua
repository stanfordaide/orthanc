-- ═══════════════════════════════════════════════════════════════════════════════
-- RADWATCH ROUTING - LOGGER
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- PURPOSE:
--   Consistent logging with levels, prefixes, and structured output.
--   Makes it easy to grep logs and understand what happened.
--
-- USAGE:
--   local Log = dofile('/path/to/logger.lua')
--   Log.info("Study received", { studyId = "abc123" })
--   Log.error("Send failed", { destination = "MERCURE", error = "timeout" })
--
-- OUTPUT FORMAT:
--   [RADWATCH] [INFO] Study received | studyId=abc123
--   [RADWATCH] [ERROR] Send failed | destination=MERCURE error=timeout
--
-- ═══════════════════════════════════════════════════════════════════════════════

-- We need Config for settings
-- NOTE: This path will be set by main.lua before loading logger.lua
local Config = _G.RadwatchConfig or {}

local Logger = {}

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 1: LOG LEVELS
-- ─────────────────────────────────────────────────────────────────────────────────
-- Higher number = more severe

Logger.LEVELS = {
    DEBUG = 1,
    INFO  = 2,
    WARN  = 3,
    ERROR = 4,
}

-- Current log level (from config, default to INFO)
Logger.currentLevel = Logger.LEVELS[
    (Config.LOGGING and Config.LOGGING.LEVEL) or "INFO"
] or Logger.LEVELS.INFO

-- Prefix for all messages
Logger.prefix = (Config.LOGGING and Config.LOGGING.PREFIX) or "[RADWATCH]"

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 2: HELPER FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────────

-- Convert a table to key=value string
-- { foo = "bar", num = 123 } → "foo=bar num=123"
local function formatContext(context)
    if not context or type(context) ~= "table" then
        return ""
    end
    
    local parts = {}
    for key, value in pairs(context) do
        -- Handle different value types
        local valueStr
        if type(value) == "string" then
            -- Escape spaces and special chars in strings
            valueStr = value:gsub("%s+", "_")
        elseif type(value) == "table" then
            valueStr = "[table]"
        elseif value == nil then
            valueStr = "[nil]"
        else
            valueStr = tostring(value)
        end
        
        table.insert(parts, key .. "=" .. valueStr)
    end
    
    -- Sort for consistent output (makes diffing logs easier)
    table.sort(parts)
    
    return table.concat(parts, " ")
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 3: CORE LOG FUNCTION
-- ─────────────────────────────────────────────────────────────────────────────────

-- Internal log function
-- @param level: string - "DEBUG", "INFO", "WARN", "ERROR"
-- @param message: string - The log message
-- @param context: table (optional) - Key-value pairs to include
local function log(level, message, context)
    -- Check if we should log at this level
    local levelNum = Logger.LEVELS[level] or Logger.LEVELS.INFO
    if levelNum < Logger.currentLevel then
        return  -- Skip this log
    end
    
    -- Build the log line
    local parts = {
        Logger.prefix,
        "[" .. level .. "]",
        message
    }
    
    -- Add context if provided
    local contextStr = formatContext(context)
    if contextStr ~= "" then
        table.insert(parts, "|")
        table.insert(parts, contextStr)
    end
    
    local logLine = table.concat(parts, " ")
    
    -- Output using Orthanc's print function
    -- This goes to Orthanc's log, which you see in `docker compose logs orthanc`
    print(logLine)
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 4: PUBLIC API
-- ─────────────────────────────────────────────────────────────────────────────────
-- These are the functions you call from other code.

function Logger.debug(message, context)
    log("DEBUG", message, context)
end

function Logger.info(message, context)
    log("INFO", message, context)
end

function Logger.warn(message, context)
    log("WARN", message, context)
end

function Logger.error(message, context)
    log("ERROR", message, context)
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 5: CONVENIENCE FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────────
-- Common logging patterns

-- Log the start of processing a study
function Logger.studyReceived(studyId, tags)
    Logger.info("Study received", {
        studyId = studyId,
        patient = tags and tags["PatientName"] or "unknown",
        description = tags and tags["StudyDescription"] or "unknown",
    })
end

-- Log a send attempt
function Logger.sendAttempt(studyId, destination, instanceId)
    Logger.info("Sending to destination", {
        studyId = studyId,
        destination = destination,
        instanceId = instanceId,
    })
end

-- Log a send result
function Logger.sendResult(studyId, destination, success, errorMsg)
    if success then
        Logger.info("Send succeeded", {
            studyId = studyId,
            destination = destination,
        })
    else
        Logger.error("Send failed", {
            studyId = studyId,
            destination = destination,
            error = errorMsg or "unknown",
        })
    end
end

-- Log a matching decision
function Logger.matchResult(studyId, matched, reason)
    local level = matched and "INFO" or "DEBUG"
    log(level, matched and "Study matched routing rules" or "Study did not match", {
        studyId = studyId,
        reason = reason,
    })
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 6: CONFIGURATION
-- ─────────────────────────────────────────────────────────────────────────────────
-- Functions to change logger settings at runtime

function Logger.setLevel(levelName)
    local level = Logger.LEVELS[levelName]
    if level then
        Logger.currentLevel = level
        Logger.info("Log level changed", { newLevel = levelName })
    else
        Logger.warn("Invalid log level", { attempted = levelName })
    end
end

function Logger.setPrefix(prefix)
    Logger.prefix = prefix
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- RETURN THE LOGGER
-- ─────────────────────────────────────────────────────────────────────────────────

return Logger
