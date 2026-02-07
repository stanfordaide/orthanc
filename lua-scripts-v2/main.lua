-- ═══════════════════════════════════════════════════════════════════════════════
-- RADWATCH ROUTING - MAIN ENTRY POINT
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- PURPOSE:
--   This is the file Orthanc loads. It:
--   1. Loads all modules
--   2. Defines Orthanc event handlers (OnStableStudy, etc.)
--   3. Ties everything together
--
-- TO ENABLE THESE SCRIPTS:
--   1. Update orthanc.json:
--      "LuaScripts": ["/etc/orthanc/lua-v2/main.lua"]
--   
--   2. Update docker-compose.yml volumes:
--      - ./lua-scripts-v2:/etc/orthanc/lua-v2:ro
--
--   3. Restart: docker compose restart orthanc
--
-- ═══════════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 1: MODULE LOADING
-- ─────────────────────────────────────────────────────────────────────────────────
-- Load all modules and make them available globally

-- Base path for all Lua modules (inside Docker container)
local LUA_BASE_PATH = "/etc/orthanc/lua-v2"

-- Helper to load a module
local function loadModule(name)
    local path = LUA_BASE_PATH .. "/" .. name .. ".lua"
    local success, result = pcall(dofile, path)
    
    if success then
        print("[RADWATCH] Loaded module: " .. name)
        return result
    else
        print("[RADWATCH] ERROR: Failed to load " .. name .. ": " .. tostring(result))
        return nil
    end
end

-- Load modules in dependency order
-- IMPORTANT: Set globals immediately after each load so dependent modules can access them

local Config = loadModule("config")
_G.RadwatchConfig = Config  -- Set global before loading modules that depend on it

local Utils = loadModule("utils")
_G.RadwatchUtils = Utils    -- Set global before loading modules that depend on it

local Log = loadModule("logger")
_G.RadwatchLog = Log        -- Set global before loading modules that depend on it

local Tracker = loadModule("tracker")
_G.RadwatchTracker = Tracker

local Matcher = loadModule("matcher")
_G.RadwatchMatcher = Matcher

local Router = loadModule("router")
_G.RadwatchRouter = Router

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 2: STARTUP
-- ─────────────────────────────────────────────────────────────────────────────────

print("═══════════════════════════════════════════════════════════════")
print("  RADWATCH Routing System v2.0")
print("═══════════════════════════════════════════════════════════════")

-- Check if all modules loaded
local allLoaded = Config and Utils and Log and Tracker and Matcher and Router

if allLoaded then
    Log.info("All modules loaded successfully")
    
    -- Skip health check at startup - API might not be ready yet
    -- Health can be checked later via CheckHealth() function
    
    -- Log configuration summary
    Log.info("Configuration loaded", {
        aiEnabled = Config.FEATURES and Config.FEATURES.AI_PROCESSING_ENABLED,
        trackingEnabled = Config.FEATURES and Config.FEATURES.TRACKING_ENABLED,
        routingEnabled = Config.FEATURES and Config.FEATURES.ROUTING_ENABLED,
    })
else
    print("[RADWATCH] ERROR: Some modules failed to load. Routing may not work!")
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 3: HELPER FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────────

--
-- Get instance details for a study
-- Orthanc hierarchy: Study -> Series -> Instances
-- We need to traverse through series to get instances
--
local function getInstancesWithTags(studyId)
    local instances = {}
    
    -- Get study info (contains Series list, not Instances directly)
    local success, studyInfo = pcall(function()
        return ParseJson(RestApiGet("/studies/" .. studyId))
    end)
    
    if not success or not studyInfo then
        Log.warn("Could not get study info", { studyId = studyId })
        return instances
    end
    
    -- Get series list
    local seriesIds = studyInfo.Series or {}
    Log.debug("Study has series", { studyId = studyId, count = #seriesIds })
    
    -- For each series, get its instances
    for _, seriesId in ipairs(seriesIds) do
        local seriesSuccess, seriesInfo = pcall(function()
            return ParseJson(RestApiGet("/series/" .. seriesId))
        end)
        
        if seriesSuccess and seriesInfo then
            local instanceIds = seriesInfo.Instances or {}
            
            -- Get tags for each instance in this series
            for _, instanceId in ipairs(instanceIds) do
                local instSuccess, instInfo = pcall(function()
                    return ParseJson(RestApiGet("/instances/" .. instanceId .. "/simplified-tags"))
                end)
                
                if instSuccess and instInfo then
                    instInfo.ID = instanceId  -- Add the ID to the tags
                    table.insert(instances, instInfo)
                else
                    Log.warn("Could not get instance tags", { instanceId = instanceId })
                end
            end
        else
            Log.warn("Could not get series info", { seriesId = seriesId })
        end
    end
    
    Log.debug("Total instances found", { studyId = studyId, count = #instances })
    return instances
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 4: ORTHANC EVENT HANDLERS
-- ─────────────────────────────────────────────────────────────────────────────────
-- These are the functions Orthanc calls automatically

--
-- Called when a study is stable (all instances received)
-- This is the main entry point for routing logic
--
function OnStableStudy(studyId, tags, metadata, origin)
    -- Safety check
    if not allLoaded then
        print("[RADWATCH] ERROR: Modules not loaded, skipping study " .. tostring(studyId))
        return
    end
    
    Log.info("════════════════════════════════════════════════════════════")
    Log.info("OnStableStudy triggered", { 
        studyId = studyId,
        patient = Utils.safeGet(tags, "PatientName", "Unknown"),
        description = Utils.safeGet(tags, "StudyDescription", ""),
    })
    
    -- Track that we received this study
    if Tracker.studyReceived then
        Tracker.studyReceived(studyId, tags)
    end
    
    -- Get instance-level details
    local instances = getInstancesWithTags(studyId)
    
    if #instances == 0 then
        Log.warn("Study has no instances", { studyId = studyId })
        return
    end
    
    -- Analyze the study
    local matchResult = Matcher.analyze(studyId, tags, instances)
    
    Log.info("Match result", {
        studyId = studyId,
        shouldRoute = matchResult.shouldRoute,
        studyType = matchResult.studyType,
        reason = matchResult.reason,
    })
    
    -- Execute routing
    if matchResult.shouldRoute then
        local success = Router.execute(studyId, matchResult)
        
        if success then
            Log.info("Routing completed successfully", { studyId = studyId })
        else
            Log.error("Routing failed", { studyId = studyId })
        end
    else
        Log.debug("Study not routed", { 
            studyId = studyId, 
            reason = matchResult.reason 
        })
    end
    
    Log.info("════════════════════════════════════════════════════════════")
end

--
-- Called when Orthanc starts (optional - for initialization)
--
function Initialize()
    Log.info("Orthanc Initialize called")
    -- Any startup logic can go here
end

--
-- Called when Orthanc is shutting down (optional - for cleanup)
--
function Finalize()
    Log.info("Orthanc Finalize called - shutting down")
    -- Any cleanup logic can go here
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 5: DEBUG HELPERS (can be called from Orthanc's Lua console)
-- ─────────────────────────────────────────────────────────────────────────────────

--
-- Test matching against a study description
-- Usage from Lua console: TestMatch("EXTREMITY BILATERAL BONE LENGTH")
--
function TestMatch(description)
    print("Testing match for: " .. tostring(description))
    
    local fakeTags = { StudyDescription = description }
    local result = Matcher.analyze("test-study", fakeTags, {})
    
    print("  shouldRoute: " .. tostring(result.shouldRoute))
    print("  studyType: " .. tostring(result.studyType))
    print("  reason: " .. tostring(result.reason))
    print("  matchedPattern: " .. tostring(result.matchedPattern))
    
    return result
end

--
-- Show current configuration
-- Usage from Lua console: ShowConfig()
--
function ShowConfig()
    print("=== RADWATCH Configuration ===")
    print("Routing enabled: " .. tostring(Config.FEATURES and Config.FEATURES.ROUTING_ENABLED))
    print("AI enabled: " .. tostring(Config.FEATURES and Config.FEATURES.AI_PROCESSING_ENABLED))
    print("Tracking enabled: " .. tostring(Config.FEATURES and Config.FEATURES.TRACKING_ENABLED))
    print("")
    print("Destinations:")
    for k, v in pairs(Config.DESTINATIONS or {}) do
        print("  " .. k .. " = " .. v)
    end
    print("")
    print("Patterns:")
    for i, p in ipairs(Config.MATCHING and Config.MATCHING.BONE_LENGTH_PATTERNS or {}) do
        print("  " .. i .. ". " .. p)
    end
    print("==============================")
end

--
-- Check tracking API health
-- Usage from Lua console: CheckHealth()
--
function CheckHealth()
    print("Checking tracking API health...")
    local healthy, msg = Tracker.healthCheck()
    print("  Healthy: " .. tostring(healthy))
    print("  Message: " .. tostring(msg))
    return healthy
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 7: MANUAL INTERVENTION FUNCTIONS
-- ─────────────────────────────────────────────────────────────────────────────────
-- These functions allow operators to manually trigger routing operations

--
-- Reprocess a study that's already in Orthanc
-- Use this to re-run the routing logic for a study
--
-- @param studyId: string - Orthanc study ID
-- @return success: boolean
--
-- Usage from Lua console or /tools/execute-script:
--   ReprocessStudy("3f00cf17-82c42772-d73f3732-9067cd55-516acded")
--
function ReprocessStudy(studyId)
    print("[RADWATCH] Manual reprocess requested for: " .. tostring(studyId))
    
    if not studyId then
        print("[RADWATCH] ERROR: studyId is required")
        return false
    end
    
    -- Fetch study tags from Orthanc
    local success, studyInfo = pcall(function()
        return ParseJson(RestApiGet("/studies/" .. studyId))
    end)
    
    if not success or not studyInfo then
        print("[RADWATCH] ERROR: Study not found: " .. tostring(studyId))
        return false
    end
    
    local tags = studyInfo.MainDicomTags or {}
    print("[RADWATCH] Found study: " .. (tags.StudyDescription or "unknown"))
    
    -- Call the main processing function
    return processStudy(studyId, tags)
end

--
-- Fresh reprocess: Clear AI output and reprocess from scratch
-- Use this when you need to completely redo AI processing
--
-- @param studyId: string - Orthanc study ID
-- @return success: boolean
--
-- Usage from Lua console or /tools/execute-script:
--   FreshReprocess("3f00cf17-82c42772-d73f3732-9067cd55-516acded")
--
function FreshReprocess(studyId)
    print("[RADWATCH] Fresh reprocess requested for: " .. tostring(studyId))
    
    if not studyId then
        print("[RADWATCH] ERROR: studyId is required")
        return false
    end
    
    -- Use Router.freshReprocess with processStudy as the callback
    return Router.freshReprocess(studyId, processStudy)
end

--
-- Clear AI output from a study without reprocessing
-- Use this to just remove AI-generated series
--
-- @param studyId: string - Orthanc study ID
-- @return deletedCount: number
--
-- Usage from Lua console or /tools/execute-script:
--   ClearAIOutput("3f00cf17-82c42772-d73f3732-9067cd55-516acded")
--
function ClearAIOutput(studyId)
    print("[RADWATCH] Clear AI output requested for: " .. tostring(studyId))
    
    if not studyId then
        print("[RADWATCH] ERROR: studyId is required")
        return 0
    end
    
    local deletedCount, deletedSeries = Router.clearAIOutput(studyId)
    print("[RADWATCH] Deleted " .. deletedCount .. " AI output series")
    
    return deletedCount
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- STARTUP COMPLETE
-- ─────────────────────────────────────────────────────────────────────────────────

print("[RADWATCH] Main script loaded. Waiting for studies...")
print("[RADWATCH] Manual intervention functions available:")
print("  - ReprocessStudy(studyId)  : Re-run routing for existing study")
print("  - FreshReprocess(studyId)  : Clear AI output and reprocess from scratch")
print("  - ClearAIOutput(studyId)   : Remove AI-generated series only")
print("═══════════════════════════════════════════════════════════════")
