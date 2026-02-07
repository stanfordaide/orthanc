-- ═══════════════════════════════════════════════════════════════════════════════
-- RADWATCH ROUTING - ROUTER
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- PURPOSE:
--   Execute the actual DICOM sends. Takes decisions from Matcher and acts on them.
--   This is the "action" logic - separate from "decision" logic in matcher.lua
--
-- USAGE:
--   local Router = dofile('/path/to/router.lua')
--   
--   -- Route based on analysis result
--   Router.execute(studyId, matchResult)
--
-- ORTHANC FUNCTIONS USED:
--   SendToModality(instanceId, modalityName) - Send instance to destination
--   These are Orthanc built-ins available in Lua context
--
-- ═══════════════════════════════════════════════════════════════════════════════

-- Dependencies (set by main.lua before loading)
local Config = _G.RadwatchConfig or {}
local Utils = _G.RadwatchUtils or {}
local Log = _G.RadwatchLog or { info = print, warn = print, error = print }
local Tracker = _G.RadwatchTracker or {}
local Matcher = _G.RadwatchMatcher or {}

local Router = {}

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 1: CONFIGURATION HELPERS
-- ─────────────────────────────────────────────────────────────────────────────────

-- Get destination name from config
local function getDestination(key)
    return Config.DESTINATIONS and Config.DESTINATIONS[key] or key
end

-- Check if routing is enabled
local function isRoutingEnabled()
    return Config.FEATURES and Config.FEATURES.ROUTING_ENABLED ~= false
end

-- Check if AI processing is enabled
local function isAIEnabled()
    return Config.FEATURES and Config.FEATURES.AI_PROCESSING_ENABLED ~= false
end

-- Check if final routing is enabled
local function isFinalRoutingEnabled()
    return Config.FEATURES and Config.FEATURES.FINAL_ROUTING_ENABLED ~= false
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 2: SEND HELPERS
-- ─────────────────────────────────────────────────────────────────────────────────

--
-- Send a single instance to a destination
-- Wraps SendToModality with logging and tracking
--
-- @param studyId: string - For tracking
-- @param instanceId: string - Orthanc instance ID
-- @param destination: string - Modality name
-- @return success: boolean, jobId: string or error
--
local function sendInstance(studyId, instanceId, destination)
    Log.info("Sending instance", {
        studyId = studyId,
        instanceId = instanceId,
        destination = destination,
    })
    
    -- Attempt the send
    local success, result = Utils.try(function()
        return SendToModality(instanceId, destination)
    end)
    
    -- Track the result
    local errorMsg = nil
    if not success then
        errorMsg = tostring(result):sub(1, 200)
        Log.error("Send failed", {
            studyId = studyId,
            destination = destination,
            error = errorMsg,
        })
    else
        Log.info("Send succeeded", {
            studyId = studyId,
            destination = destination,
            jobId = tostring(result),
        })
    end
    
    -- Record in tracking database
    if Tracker.sendAttempted then
        Tracker.sendAttempted(studyId, destination, success, errorMsg)
    end
    
    return success, result
end

--
-- Send multiple instances to a destination
-- 
-- @param studyId: string
-- @param instances: array of instance tables (must have ID field)
-- @param destination: string
-- @return successCount: number, failCount: number
--
local function sendInstances(studyId, instances, destination)
    local successCount = 0
    local failCount = 0
    
    for _, instance in ipairs(instances or {}) do
        local instanceId = Utils.safeGet(instance, "ID", nil)
        if instanceId then
            local success = sendInstance(studyId, instanceId, destination)
            if success then
                successCount = successCount + 1
            else
                failCount = failCount + 1
            end
        else
            Log.warn("Instance missing ID", { studyId = studyId })
            failCount = failCount + 1
        end
    end
    
    return successCount, failCount
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 3: ROUTING STRATEGIES
-- ─────────────────────────────────────────────────────────────────────────────────

--
-- Route ORIGINAL study to MERCURE for AI processing
--
local function routeToAI(studyId, matchResult)
    if not isAIEnabled() then
        Log.info("AI processing disabled, skipping MERCURE", { studyId = studyId })
        return true
    end
    
    local instance = matchResult.selectedInstances and matchResult.selectedInstances.forAI
    if not instance then
        Log.warn("No instance selected for AI", { studyId = studyId })
        return false
    end
    
    local instanceId = Utils.safeGet(instance, "ID", nil)
    if not instanceId then
        Log.warn("Selected instance has no ID", { studyId = studyId })
        return false
    end
    
    local destination = getDestination("MERCURE")
    return sendInstance(studyId, instanceId, destination)
end

--
-- Route AI_RESULT study to final destinations
--
local function routeToFinalDestinations(studyId, matchResult)
    if not isFinalRoutingEnabled() then
        Log.info("Final routing disabled, skipping", { studyId = studyId })
        return true
    end
    
    local selected = matchResult.selectedInstances or {}
    local totalSuccess = 0
    local totalFail = 0
    
    -- Route QA Visualization to LPCH and LPCHT
    local qaViz = selected.qaVisualization or {}
    if #qaViz > 0 then
        Log.info("Routing QA Visualization", { count = #qaViz })
        
        local s1, f1 = sendInstances(studyId, qaViz, getDestination("LPCH"))
        local s2, f2 = sendInstances(studyId, qaViz, getDestination("LPCHT"))
        
        totalSuccess = totalSuccess + s1 + s2
        totalFail = totalFail + f1 + f2
    else
        Log.debug("No QA Visualization instances to route", { studyId = studyId })
    end
    
    -- Route Structured Reports to MODLINK
    local sr = selected.structuredReports or {}
    if #sr > 0 then
        Log.info("Routing Structured Reports", { count = #sr })
        
        local s, f = sendInstances(studyId, sr, getDestination("MODLINK"))
        totalSuccess = totalSuccess + s
        totalFail = totalFail + f
    else
        Log.debug("No Structured Report instances to route", { studyId = studyId })
    end
    
    Log.info("Final routing complete", {
        studyId = studyId,
        sent = totalSuccess,
        failed = totalFail,
    })
    
    return totalFail == 0
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 4: MAIN EXECUTE FUNCTION
-- ─────────────────────────────────────────────────────────────────────────────────

--
-- Execute routing based on Matcher analysis result
--
-- @param studyId: string - Orthanc study ID
-- @param matchResult: table - Result from Matcher.analyze()
-- @return success: boolean
--
function Router.execute(studyId, matchResult)
    -- Safety checks
    if not matchResult then
        Log.warn("Router.execute called with nil matchResult", { studyId = studyId })
        return false
    end
    
    if not matchResult.shouldRoute then
        Log.debug("matchResult says don't route", {
            studyId = studyId,
            reason = matchResult.reason,
        })
        return true  -- Not routing is "success" if that's the decision
    end
    
    -- Check master switch
    if not isRoutingEnabled() then
        Log.info("Routing disabled globally", { studyId = studyId })
        return true
    end
    
    -- Route based on study type
    local studyType = matchResult.studyType
    
    if studyType == Matcher.STUDY_TYPES.ORIGINAL then
        -- Fresh study → send to MERCURE for AI
        Log.info("Routing ORIGINAL study to AI", { studyId = studyId })
        return routeToAI(studyId, matchResult)
        
    elseif studyType == Matcher.STUDY_TYPES.AI_RESULT then
        -- AI result → send to final destinations
        Log.info("Routing AI_RESULT to final destinations", { studyId = studyId })
        
        -- Track that AI results were received
        if Tracker.aiResultsReceived then
            Tracker.aiResultsReceived(studyId)
        end
        
        return routeToFinalDestinations(studyId, matchResult)
        
    else
        -- Unknown type
        Log.warn("Unknown study type", {
            studyId = studyId,
            studyType = studyType,
        })
        return false
    end
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 5: MANUAL ROUTING HELPERS
-- ─────────────────────────────────────────────────────────────────────────────────
-- For manual intervention / retries from the UI

--
-- Manually send a study to a specific destination
-- Used for retries or manual routing
--
-- @param studyId: string - Orthanc study ID
-- @param destination: string - Destination name
-- @param instanceIds: array of strings (optional - if nil, sends all)
-- @return success: boolean
--
function Router.manualSend(studyId, destination, instanceIds)
    Log.info("Manual send requested", {
        studyId = studyId,
        destination = destination,
        instanceCount = instanceIds and #instanceIds or "all",
    })
    
    -- If no specific instances, we'd need to get them from Orthanc
    -- This would require RestApiGet to the study - leaving as TODO
    if not instanceIds or #instanceIds == 0 then
        Log.warn("Manual send requires instanceIds", { studyId = studyId })
        return false
    end
    
    local successCount = 0
    local failCount = 0
    
    for _, instanceId in ipairs(instanceIds) do
        local success = sendInstance(studyId, instanceId, destination)
        if success then
            successCount = successCount + 1
        else
            failCount = failCount + 1
        end
    end
    
    return failCount == 0
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- RETURN THE ROUTER MODULE
-- ─────────────────────────────────────────────────────────────────────────────────

return Router
