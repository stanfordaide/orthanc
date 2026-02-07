-- ═══════════════════════════════════════════════════════════════════════════════
-- RADWATCH ROUTING - MATCHER
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- PURPOSE:
--   Determine if a study should be routed, and what kind of routing.
--   This is the "decision" logic - separate from the "action" logic.
--
-- USAGE:
--   local Matcher = dofile('/path/to/matcher.lua')
--   
--   local result = Matcher.analyze(studyId, tags, instances)
--   if result.shouldRoute then
--       -- Route the study
--   end
--
-- STUDY TYPES:
--   1. ORIGINAL - Fresh study, needs AI processing (send to MERCURE)
--   2. AI_RESULT - Returned from MERCURE with AI output (route to final destinations)
--   3. UNMATCHED - Doesn't match routing rules (ignore)
--
-- ═══════════════════════════════════════════════════════════════════════════════

-- Dependencies (set by main.lua before loading)
local Config = _G.RadwatchConfig or {}
local Utils = _G.RadwatchUtils or {}
local Log = _G.RadwatchLog or { info = print, debug = print }

local Matcher = {}

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 1: STUDY TYPE CONSTANTS
-- ─────────────────────────────────────────────────────────────────────────────────

Matcher.STUDY_TYPES = {
    ORIGINAL = "ORIGINAL",     -- Needs AI processing
    AI_RESULT = "AI_RESULT",   -- Has AI output, route to final destinations
    UNMATCHED = "UNMATCHED",   -- Doesn't match any rules
}

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 2: PATTERN MATCHING HELPERS
-- ─────────────────────────────────────────────────────────────────────────────────

--
-- Check if study description matches bone length patterns
--
local function matchesBoneLengthStudy(studyDescription)
    if not studyDescription then return false, nil end
    
    local patterns = Config.MATCHING and Config.MATCHING.BONE_LENGTH_PATTERNS or {}
    local upperDesc = Utils.upper(studyDescription)
    
    for _, pattern in ipairs(patterns) do
        if upperDesc:find(Utils.upper(pattern)) then
            return true, pattern
        end
    end
    
    return false, nil
end

--
-- Check if any instance has AI result marker
-- Multiple detection methods (matching original autosend_leg_length.lua logic)
--
local function hasAIResultMarker(instances)
    for _, instance in ipairs(instances or {}) do
        -- CHECK 1: Manufacturer is STANFORDAIDE (primary AI marker)
        local manufacturer = Utils.safeGet(instance, "Manufacturer", "")
        if Utils.containsIgnoreCase(manufacturer, "STANFORDAIDE") then
            Log.debug("AI result marker found", { check = "Manufacturer", value = manufacturer })
            return true
        end
        
        -- CHECK 2: Structured Report modality (AI outputs are often SR)
        local modality = Utils.safeGet(instance, "Modality", "")
        if Utils.upper(modality) == "SR" then
            Log.debug("AI result marker found", { check = "Modality", value = modality })
            return true
        end
        
        -- CHECK 3: AI-specific series descriptions
        local seriesDesc = Utils.safeGet(instance, "SeriesDescription", "")
        if Utils.containsIgnoreCase(seriesDesc, "AI MEASUREMENTS") or 
           Utils.containsIgnoreCase(seriesDesc, "QA VISUALIZATION") then
            Log.debug("AI result marker found", { check = "SeriesDescription", value = seriesDesc })
            return true
        end
        
        -- CHECK 4: Software version pattern
        local softwareVersions = Utils.safeGet(instance, "SoftwareVersions", "")
        if Utils.containsIgnoreCase(softwareVersions, "PEDIATRIC_LEG_LENGTH_V") then
            Log.debug("AI result marker found", { check = "SoftwareVersions", value = softwareVersions })
            return true
        end
        
        -- CHECK 5: Institution/Station/Department combination
        local institutionName = Utils.safeGet(instance, "InstitutionName", "")
        local department = Utils.safeGet(instance, "InstitutionalDepartmentName", "")
        local stationName = Utils.safeGet(instance, "StationName", "")
        if Utils.upper(institutionName) == "SOM" and
           Utils.upper(department) == "RADIOLOGY" and
           Utils.upper(stationName) == "LPCH" and
           Utils.containsIgnoreCase(manufacturer, "STANFORDAIDE") then
            Log.debug("AI result marker found", { check = "InstitutionCombo" })
            return true
        end
    end
    
    return false
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 3: INSTANCE CLASSIFICATION
-- ─────────────────────────────────────────────────────────────────────────────────
-- Categorize instances for routing decisions

--
-- Find the highest resolution instance (for sending to MERCURE)
-- Returns the instance with largest Rows × Columns
--
function Matcher.findHighestResolution(instances)
    local best = nil
    local bestSize = 0
    
    for _, instance in ipairs(instances or {}) do
        local size = Utils.getMatrixSize(instance)
        if size > bestSize then
            best = instance
            bestSize = size
        end
    end
    
    if best then
        Log.debug("Found highest resolution instance", {
            instanceId = Utils.safeGet(best, "ID", "unknown"),
            size = bestSize,
        })
    end
    
    return best
end

--
-- Find QA Visualization instances (for LPCH/LPCHT)
-- Matches "QA VISUALIZATION" but excludes "TABLE"
--
function Matcher.findQAVisualization(instances)
    local results = {}
    local vizPattern = Config.MATCHING and Config.MATCHING.QA_VIZ_PATTERN or "QA VISUALIZATION"
    local excludePattern = Config.MATCHING and Config.MATCHING.QA_VIZ_EXCLUDE or "TABLE"
    
    for _, instance in ipairs(instances or {}) do
        local seriesDesc = Utils.upper(Utils.safeGet(instance, "SeriesDescription", ""))
        
        if seriesDesc:find(Utils.upper(vizPattern)) 
           and not seriesDesc:find(Utils.upper(excludePattern)) then
            table.insert(results, instance)
        end
    end
    
    Log.debug("Found QA Visualization instances", { count = #results })
    return results
end

--
-- Find AI Measurements instances
-- Matches "AI MEASUREMENTS" pattern
--
function Matcher.findAIMeasurements(instances)
    local results = {}
    local pattern = Config.MATCHING and Config.MATCHING.QA_MEASUREMENTS_PATTERN or "AI MEASUREMENTS"
    
    for _, instance in ipairs(instances or {}) do
        local seriesDesc = Utils.upper(Utils.safeGet(instance, "SeriesDescription", ""))
        
        if seriesDesc:find(Utils.upper(pattern)) then
            table.insert(results, instance)
        end
    end
    
    Log.debug("Found AI Measurements instances", { count = #results })
    return results
end

--
-- Find Structured Report instances (for MODLINK)
-- Matches Modality = "SR"
--
function Matcher.findStructuredReports(instances)
    local results = {}
    
    for _, instance in ipairs(instances or {}) do
        local modality = Utils.safeGet(instance, "Modality", "")
        if Utils.upper(modality) == "SR" then
            table.insert(results, instance)
        end
    end
    
    Log.debug("Found Structured Report instances", { count = #results })
    return results
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 4: MAIN ANALYSIS FUNCTION
-- ─────────────────────────────────────────────────────────────────────────────────

--
-- Analyze a study and determine routing action
--
-- @param studyId: string - Orthanc study ID
-- @param tags: table - Study-level DICOM tags
-- @param instances: table - Array of instance info (with tags)
--
-- @return table:
--   {
--     shouldRoute: boolean,
--     studyType: string,         -- ORIGINAL, AI_RESULT, or UNMATCHED
--     reason: string,            -- Why this decision was made
--     matchedPattern: string,    -- Which pattern matched (if any)
--     selectedInstances: table,  -- Instances to route (varies by type)
--   }
--
function Matcher.analyze(studyId, tags, instances)
    local result = {
        shouldRoute = false,
        studyType = Matcher.STUDY_TYPES.UNMATCHED,
        reason = "",
        matchedPattern = nil,
        selectedInstances = {},
    }
    
    -- Safety check
    if not studyId then
        result.reason = "no_study_id"
        return result
    end
    
    local studyDesc = Utils.safeGet(tags, "StudyDescription", "")
    
    -- ─────────────────────────────────────────────────────────────────────────────
    -- CHECK 1: Is this an AI result coming back from MERCURE?
    -- ─────────────────────────────────────────────────────────────────────────────
    if hasAIResultMarker(instances) then
        result.shouldRoute = true
        result.studyType = Matcher.STUDY_TYPES.AI_RESULT
        result.reason = "contains_ai_output"
        
        -- Collect instances for final routing
        result.selectedInstances = {
            qaVisualization = Matcher.findQAVisualization(instances),
            aiMeasurements = Matcher.findAIMeasurements(instances),
            structuredReports = Matcher.findStructuredReports(instances),
        }
        
        Log.info("Study identified as AI result", {
            studyId = studyId,
            qaVizCount = #result.selectedInstances.qaVisualization,
            measurementsCount = #result.selectedInstances.aiMeasurements,
            srCount = #result.selectedInstances.structuredReports,
        })
        
        return result
    end
    
    -- ─────────────────────────────────────────────────────────────────────────────
    -- CHECK 2: Does this match our routing patterns?
    -- IMPORTANT: Only send to MERCURE if study does NOT already have AI output
    -- This is a safety check to prevent re-processing studies that already went
    -- through AI pipeline (defense in depth - CHECK 1 should catch this, but
    -- this ensures we never accidentally re-send to MERCURE)
    -- ─────────────────────────────────────────────────────────────────────────────
    local matches, pattern = matchesBoneLengthStudy(studyDesc)
    
    if matches then
        -- SAFETY: Double-check that this study doesn't already have AI output
        -- This prevents infinite loops if hasAIResultMarker somehow missed it
        if hasAIResultMarker(instances) then
            Log.warn("Study matches bone length pattern but ALREADY has AI output - skipping MERCURE", {
                studyId = studyId,
                pattern = pattern,
            })
            result.reason = "already_has_ai_output"
            return result
        end
        
        result.shouldRoute = true
        result.studyType = Matcher.STUDY_TYPES.ORIGINAL
        result.reason = "matches_bone_length_pattern"
        result.matchedPattern = pattern
        
        -- Find the best instance for AI processing
        local highRes = Matcher.findHighestResolution(instances)
        if highRes then
            result.selectedInstances = { forAI = highRes }
        else
            -- No suitable instance found - still match but flag it
            result.reason = "matches_pattern_but_no_suitable_instance"
            result.shouldRoute = false
        end
        
        Log.info("Study matched routing pattern", {
            studyId = studyId,
            pattern = pattern,
            hasInstance = highRes ~= nil,
        })
        
        return result
    end
    
    -- ─────────────────────────────────────────────────────────────────────────────
    -- NO MATCH
    -- ─────────────────────────────────────────────────────────────────────────────
    result.reason = "no_matching_pattern"
    
    Log.debug("Study did not match routing rules", {
        studyId = studyId,
        studyDesc = studyDesc,
    })
    
    return result
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 5: UTILITIES FOR DEBUGGING
-- ─────────────────────────────────────────────────────────────────────────────────

--
-- Get a summary of what would match (for testing)
--
function Matcher.describePatterns()
    local patterns = Config.MATCHING and Config.MATCHING.BONE_LENGTH_PATTERNS or {}
    local aiPatterns = Config.MATCHING and Config.MATCHING.AI_RESULT_PATTERNS 
                       or { "AI MEASUREMENTS", "QA VISUALIZATION", "STANFORDAIDE" }
    
    print("=== Matcher Patterns ===")
    print("Bone Length Patterns:")
    for i, p in ipairs(patterns) do
        print("  " .. i .. ". " .. p)
    end
    print("AI Result Patterns:")
    for i, p in ipairs(aiPatterns) do
        print("  " .. i .. ". " .. p)
    end
    print("QA Viz Pattern: " .. (Config.MATCHING and Config.MATCHING.QA_VIZ_PATTERN or "QA VISUALIZATION"))
    print("========================")
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- RETURN THE MATCHER MODULE
-- ─────────────────────────────────────────────────────────────────────────────────

return Matcher
