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
-- SECTION 6: RECOVERY / CLEANUP FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────────
-- Functions for manual intervention: clearing AI output, fresh reprocessing

--
-- Check if a series is AI output (should be deleted for fresh reprocess)
-- Uses the same detection logic as Matcher
--
-- @param seriesId: string - Orthanc series ID
-- @return isAIOutput: boolean, reason: string
--
local function isAIOutputSeries(seriesId)
    -- Get series info to find an instance
    local success, seriesInfo = pcall(function()
        return ParseJson(RestApiGet("/series/" .. seriesId))
    end)
    
    if not success or not seriesInfo then
        Log.warn("Could not get series info", { seriesId = seriesId })
        return false, "unknown"
    end
    
    local instances = seriesInfo.Instances or {}
    if #instances == 0 then
        return false, "no_instances"
    end
    
    -- Check first instance's tags
    local instSuccess, tags = pcall(function()
        return ParseJson(RestApiGet("/instances/" .. instances[1] .. "/simplified-tags"))
    end)
    
    if not instSuccess or not tags then
        return false, "no_tags"
    end
    
    -- Check 1: Manufacturer is StanfordAIDE
    local manufacturer = tags.Manufacturer or ""
    if Utils.containsIgnoreCase(manufacturer, "STANFORDAIDE") then
        return true, "manufacturer_stanfordaide"
    end
    
    -- Check 2: Modality is SR (Structured Report)
    local modality = tags.Modality or ""
    if Utils.upper(modality) == "SR" then
        return true, "modality_sr"
    end
    
    -- Check 3: SeriesDescription matches AI patterns
    local seriesDesc = tags.SeriesDescription or ""
    if Utils.containsIgnoreCase(seriesDesc, "AI MEASUREMENTS") or
       Utils.containsIgnoreCase(seriesDesc, "QA VISUALIZATION") then
        return true, "series_description_ai"
    end
    
    -- Check 4: SoftwareVersions contains AI marker
    local softwareVersions = tags.SoftwareVersions or ""
    if Utils.containsIgnoreCase(softwareVersions, "PEDIATRIC_LEG_LENGTH_V") then
        return true, "software_version_ai"
    end
    
    return false, "original"
end

--
-- Clear all AI output series from a study
-- This removes StanfordAIDE-generated series so the study can be reprocessed fresh
--
-- @param studyId: string - Orthanc study ID
-- @return deletedCount: number, deletedSeries: table
--
function Router.clearAIOutput(studyId)
    Log.info("Clearing AI output from study", { studyId = studyId })
    
    -- Get study info
    local success, studyInfo = pcall(function()
        return ParseJson(RestApiGet("/studies/" .. studyId))
    end)
    
    if not success or not studyInfo then
        Log.error("Could not get study info", { studyId = studyId })
        return 0, {}
    end
    
    local seriesIds = studyInfo.Series or {}
    local deletedCount = 0
    local deletedSeries = {}
    local keptCount = 0
    
    Log.info("Checking series for AI output", { 
        studyId = studyId, 
        totalSeries = #seriesIds 
    })
    
    for _, seriesId in ipairs(seriesIds) do
        local isAI, reason = isAIOutputSeries(seriesId)
        
        if isAI then
            -- Delete the AI output series
            local deleteSuccess = pcall(function()
                RestApiDelete("/series/" .. seriesId)
            end)
            
            if deleteSuccess then
                Log.info("Deleted AI output series", { 
                    seriesId = seriesId, 
                    reason = reason 
                })
                deletedCount = deletedCount + 1
                table.insert(deletedSeries, { id = seriesId, reason = reason })
            else
                Log.error("Failed to delete series", { seriesId = seriesId })
            end
        else
            keptCount = keptCount + 1
            Log.debug("Keeping original series", { 
                seriesId = seriesId, 
                reason = reason 
            })
        end
    end
    
    Log.info("AI output cleared", { 
        studyId = studyId,
        deleted = deletedCount,
        kept = keptCount
    })
    
    return deletedCount, deletedSeries
end

--
-- Get study tags from Orthanc REST API
-- Used when reprocessing (we don't have tags from an event)
--
-- @param studyId: string - Orthanc study ID
-- @return tags: table or nil
--
local function getStudyTags(studyId)
    local success, studyInfo = pcall(function()
        return ParseJson(RestApiGet("/studies/" .. studyId))
    end)
    
    if success and studyInfo then
        return studyInfo.MainDicomTags or {}
    end
    return nil
end

--
-- Fresh reprocess: Clear AI output and reprocess study from scratch
-- This is the main function for manual intervention
--
-- @param studyId: string - Orthanc study ID
-- @param processFunc: function - The processStudy function from main.lua
-- @return success: boolean
--
function Router.freshReprocess(studyId, processFunc)
    Log.info("═══════════════════════════════════════════════════════════")
    Log.info("Starting FRESH REPROCESS", { studyId = studyId })
    
    -- Step 1: Verify study exists
    local tags = getStudyTags(studyId)
    if not tags then
        Log.error("Study not found", { studyId = studyId })
        return false
    end
    
    Log.info("Study found", { 
        studyId = studyId,
        description = tags.StudyDescription or "unknown"
    })
    
    -- Step 2: Clear AI output
    local deletedCount, deletedSeries = Router.clearAIOutput(studyId)
    
    -- Step 3: Reset tracking state
    if Tracker and Tracker.resetStudy then
        Log.info("Resetting tracking state", { studyId = studyId })
        Tracker.resetStudy(studyId)
    else
        Log.warn("Tracker.resetStudy not available, skipping tracking reset")
    end
    
    -- Step 4: Re-fetch tags (in case clearing changed something)
    tags = getStudyTags(studyId)
    if not tags then
        Log.error("Study disappeared after clearing AI output", { studyId = studyId })
        return false
    end
    
    -- Step 5: Reprocess using the provided function
    if processFunc then
        Log.info("Reprocessing study", { studyId = studyId })
        local success = processFunc(studyId, tags)
        Log.info("Fresh reprocess complete", { 
            studyId = studyId, 
            success = success 
        })
        Log.info("═══════════════════════════════════════════════════════════")
        return success
    else
        Log.warn("No processFunc provided, cannot reprocess")
        return false
    end
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- RETURN THE ROUTER MODULE
-- ─────────────────────────────────────────────────────────────────────────────────

return Router
