-- ═══════════════════════════════════════════════════════════════════════════════
-- RADWATCH ROUTING - TRACKER
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- PURPOSE:
--   Communicate with the routing-api to track workflow state.
--   Each study's progress is recorded in PostgreSQL via the API.
--
-- USAGE:
--   local Tracker = dofile('/path/to/tracker.lua')
--   Tracker.studyReceived(studyId, tags)
--   Tracker.sendAttempted(studyId, "MERCURE", true)
--   Tracker.aiResultsReceived(studyId)
--
-- WHY TRACK?
--   - Know what happened to each study
--   - Identify stuck/failed workflows
--   - Manual intervention for failures
--   - QI dashboards and metrics
--
-- ═══════════════════════════════════════════════════════════════════════════════

-- Dependencies (set by main.lua before loading)
local Config = _G.RadwatchConfig or {}
local Utils = _G.RadwatchUtils or {}
local Log = _G.RadwatchLog or { info = print, warn = print, error = print }

local Tracker = {}

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 1: CONFIGURATION
-- ─────────────────────────────────────────────────────────────────────────────────

-- Build full URL from base and endpoint
local function buildUrl(endpoint)
    local base = (Config.API and Config.API.BASE_URL) or "http://routing-api:5000"
    return base .. endpoint
end

-- Check if tracking is enabled
local function isEnabled()
    return Config.FEATURES and Config.FEATURES.TRACKING_ENABLED ~= false
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 2: CORE API CALL
-- ─────────────────────────────────────────────────────────────────────────────────

-- Make a tracked API call with error handling
-- @param endpoint: string - API endpoint path
-- @param payload: table - Data to send
-- @return success: boolean, response: string or error message
local function apiCall(endpoint, payload)
    -- Check if tracking is enabled
    if not isEnabled() then
        Log.debug("Tracking disabled, skipping API call", { endpoint = endpoint })
        return true, "tracking_disabled"
    end
    
    local url = buildUrl(endpoint)
    local jsonPayload = Utils.toJson(payload)
    
    Log.debug("API call", { url = url, payload = jsonPayload })
    
    -- Make the HTTP request (Orthanc's HttpPost doesn't take content-type arg)
    local success, response = Utils.httpPost(url, jsonPayload)
    
    if success then
        Log.debug("API call succeeded", { url = url })
        return true, response
    else
        -- Log but don't crash - tracking failures shouldn't stop routing
        Log.warn("API call failed", { 
            url = url, 
            error = tostring(response):sub(1, 100)  -- Truncate long errors
        })
        return false, response
    end
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 3: WORKFLOW TRACKING FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────────

--
-- Track when a new study is received
-- Called at the start of OnStableStudy
--
-- @param studyId: string - Orthanc study ID
-- @param tags: table - DICOM tags
--
function Tracker.studyReceived(studyId, tags)
    if not studyId then
        Log.warn("studyReceived called without studyId")
        return false
    end
    
    -- Extract values as plain strings to avoid Json::LogicError
    -- (Orthanc's tags object may not be a simple Lua table)
    local studyUid = ""
    local patientName = "Unknown"
    local studyDesc = ""
    
    if tags then
        if tags.StudyInstanceUID then studyUid = tostring(tags.StudyInstanceUID) end
        if tags.PatientName then patientName = tostring(tags.PatientName) end
        if tags.StudyDescription then studyDesc = tostring(tags.StudyDescription) end
    end
    
    local payload = {
        study_id = tostring(studyId),
        study_instance_uid = studyUid,
        patient_name = patientName,
        study_description = studyDesc,
    }
    
    local endpoint = (Config.API and Config.API.ENDPOINTS and Config.API.ENDPOINTS.TRACK_START) 
                     or "/track/start"
    
    return apiCall(endpoint, payload)
end

--
-- Track when we attempt to send to a destination
-- Called after SendToModality
--
-- @param studyId: string - Orthanc study ID
-- @param destination: string - Destination name (e.g., "MERCURE", "LPCHROUTER")
-- @param success: boolean - Did the send succeed?
-- @param errorMsg: string (optional) - Error message if failed
--
function Tracker.sendAttempted(studyId, destination, success, errorMsg)
    if not studyId then
        Log.warn("sendAttempted called without studyId")
        return false
    end
    
    local payload = {
        study_id = studyId,
        destination = destination,
        success = success,
        error = errorMsg,
    }
    
    local endpoint = (Config.API and Config.API.ENDPOINTS and Config.API.ENDPOINTS.TRACK_SEND)
                     or "/track/destination"
    
    return apiCall(endpoint, payload)
end

--
-- Track when AI results are received back from MERCURE
-- Called when we detect a study with "STANFORDAIDE" in SeriesDescription
--
-- @param studyId: string - Orthanc study ID (of the returned study)
--
function Tracker.aiResultsReceived(studyId)
    Log.info("aiResultsReceived called", { studyId = studyId or "nil" })
    
    if not studyId then
        Log.warn("aiResultsReceived called without studyId")
        return false
    end
    
    local payload = {
        study_id = tostring(studyId),
    }
    
    local endpoint = (Config.API and Config.API.ENDPOINTS and Config.API.ENDPOINTS.TRACK_AI)
                     or "/track/ai-results"
    
    Log.info("Tracking AI results received", { studyId = studyId, endpoint = endpoint })
    return apiCall(endpoint, payload)
end

--
-- Reset a study's tracking state for fresh reprocessing
-- Clears all workflow data so the study can go through the pipeline again
--
-- @param studyId: string - Orthanc study ID
--
function Tracker.resetStudy(studyId)
    Log.info("resetStudy called", { studyId = studyId or "nil" })
    
    if not studyId then
        Log.warn("resetStudy called without studyId")
        return false
    end
    
    local payload = {
        study_id = tostring(studyId),
    }
    
    local endpoint = "/track/reset"
    
    Log.info("Resetting study tracking state", { studyId = studyId, endpoint = endpoint })
    return apiCall(endpoint, payload)
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 4: CONVENIENCE WRAPPERS
-- ─────────────────────────────────────────────────────────────────────────────────
-- These combine tracking with logging for cleaner calling code

--
-- Track and log a send attempt (combines Tracker + Log)
--
-- @param studyId: string - Orthanc study ID  
-- @param destination: string - Destination name
-- @param instanceId: string - Instance being sent
-- @param sendFunc: function - Function that does the actual send
-- @return success: boolean, result: any
--
function Tracker.trackSend(studyId, destination, instanceId, sendFunc)
    Log.sendAttempt(studyId, destination, instanceId)
    
    -- Attempt the send
    local success, result = Utils.try(sendFunc)
    
    -- Log the result
    local errorMsg = nil
    if not success then
        errorMsg = tostring(result):sub(1, 200)  -- Truncate long errors
    end
    Log.sendResult(studyId, destination, success, errorMsg)
    
    -- Track in database
    Tracker.sendAttempted(studyId, destination, success, errorMsg)
    
    return success, result
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 5: HEALTH CHECK
-- ─────────────────────────────────────────────────────────────────────────────────

--
-- Check if the tracking API is reachable
-- Can be called at startup or periodically
--
-- @return healthy: boolean, message: string
--
function Tracker.healthCheck()
    local endpoint = (Config.API and Config.API.ENDPOINTS and Config.API.ENDPOINTS.HEALTH)
                     or "/health"
    local url = buildUrl(endpoint)
    
    local success, response = Utils.httpGet(url)
    
    if success then
        Log.info("Tracking API healthy", { url = url })
        return true, "healthy"
    else
        Log.warn("Tracking API unreachable", { url = url, error = tostring(response) })
        return false, tostring(response)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- RETURN THE TRACKER MODULE
-- ─────────────────────────────────────────────────────────────────────────────────

return Tracker
