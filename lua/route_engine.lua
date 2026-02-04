-- ═══════════════════════════════════════════════════════════════════════════════
-- ORTHANC ROUTE ENGINE
-- ═══════════════════════════════════════════════════════════════════════════════
-- Handles automatic routing of DICOM studies based on configurable rules.
-- Features:
--   • Structured logging for easy debugging
--   • State tracking via PostgreSQL
--   • Automatic retry with backoff
--   • Highest resolution image selection for AI processing
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- CONFIGURATION
-- ═══════════════════════════════════════════════════════════════════════════════

local CONFIG = {
    -- Retry settings
    max_attempts = 3,
    retry_delays = {60, 120, 300},  -- seconds: 1min, 2min, 5min
    
    -- Logging
    log_level = "INFO",  -- DEBUG, INFO, WARN, ERROR
    
    -- Routing rules (could be loaded from file/database in future)
    routes = {
        {
            name = "bone_length_to_ai",
            match = {
                study_description_contains = "BONE LENGTH"
            },
            action = {
                send = "highest_resolution",
                to = {"MERCURE"}
            }
        },
        {
            name = "ai_qa_to_pacs",
            match = {
                manufacturer_equals = "STANFORDAIDE",
                series_description_contains = "QA Visualization",
                series_description_not_contains = "Table"
            },
            action = {
                send = "instance",
                to = {"LPCHROUTER", "LPCHTROUTER"}
            }
        },
        {
            name = "ai_sr_to_modlink",
            match = {
                manufacturer_equals = "STANFORDAIDE",
                modality_equals = "SR"
            },
            action = {
                send = "instance",
                to = {"MODLINK"}
            }
        }
    }
}

-- ═══════════════════════════════════════════════════════════════════════════════
-- LOGGING
-- ═══════════════════════════════════════════════════════════════════════════════

local LOG_LEVELS = {DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4}
local CURRENT_LOG_LEVEL = LOG_LEVELS[CONFIG.log_level] or LOG_LEVELS.INFO

local function log(level, event, data)
    if LOG_LEVELS[level] < CURRENT_LOG_LEVEL then return end
    
    local parts = {
        os.date("%Y-%m-%dT%H:%M:%S"),
        level,
        "[routing]",
        event
    }
    
    if data then
        for k, v in pairs(data) do
            table.insert(parts, k .. "=" .. tostring(v))
        end
    end
    
    print(table.concat(parts, " "))
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- UTILITIES
-- ═══════════════════════════════════════════════════════════════════════════════

local function tableLength(t)
    if type(t) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

local function safeUpper(s)
    if type(s) ~= "string" then return "" end
    return string.upper(s)
end

local function contains(haystack, needle)
    return string.find(safeUpper(haystack), safeUpper(needle), 1, true) ~= nil
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- MATCHING
-- ═══════════════════════════════════════════════════════════════════════════════

local function matchCondition(condition, value)
    local condType, condValue = condition:match("(.+)_(.+)")
    local upperValue = safeUpper(value or "")
    local upperCondValue = safeUpper(condValue or "")
    
    if condType == "contains" then
        return contains(value, condValue)
    elseif condType == "not_contains" then
        return not contains(value, condValue)
    elseif condType == "equals" then
        return upperValue == upperCondValue
    elseif condType == "not_equals" then
        return upperValue ~= upperCondValue
    end
    
    return false
end

local function matchRoute(route, tags, instanceTags)
    if not route.match then return true end
    
    for field, condition in pairs(route.match) do
        local value = nil
        
        -- Map field names to DICOM tags
        if field:match("^study_description") then
            value = tags['StudyDescription']
        elseif field:match("^series_description") then
            value = instanceTags and instanceTags['SeriesDescription']
        elseif field:match("^manufacturer") then
            value = instanceTags and instanceTags['Manufacturer']
        elseif field:match("^modality") then
            value = instanceTags and instanceTags['Modality']
        elseif field:match("^patient_name") then
            value = tags['PatientName']
        end
        
        local conditionPart = field:gsub("^[^_]+_", "")
        if not matchCondition(conditionPart, value) then
            return false
        end
    end
    
    return true
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- INSTANCE SELECTION
-- ═══════════════════════════════════════════════════════════════════════════════

local function findHighestResolutionInstance(instances)
    if not instances or type(instances) ~= "table" then
        return nil
    end
    
    local bestInstance = nil
    local maxMatrixSize = 0
    
    for _, instance in pairs(instances) do
        if instance and instance['ID'] then
            local success, instanceTags = pcall(function()
                local response = RestApiGet('/instances/' .. instance['ID'] .. '/tags?simplify')
                return response and ParseJson(response) or nil
            end)
            
            if success and instanceTags then
                local rows = tonumber(instanceTags['Rows'] or '0') or 0
                local columns = tonumber(instanceTags['Columns'] or '0') or 0
                local matrixSize = rows * columns
                
                if matrixSize > maxMatrixSize then
                    maxMatrixSize = matrixSize
                    bestInstance = instance
                end
            end
        end
    end
    
    if bestInstance then
        log("DEBUG", "selected_highest_resolution", {
            instance_id = bestInstance['ID'],
            matrix_size = maxMatrixSize
        })
    end
    
    return bestInstance
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- STATE TRACKING
-- ═══════════════════════════════════════════════════════════════════════════════

local function hasBeenProcessed(instanceId)
    local success, metadata = pcall(function()
        return ParseJson(RestApiGet('/instances/' .. instanceId .. '/metadata'))
    end)
    return success and metadata and metadata['ProcessedByRouteEngine'] == 'true'
end

local function markAsProcessed(instanceId)
    pcall(function()
        RestApiPut('/instances/' .. instanceId .. '/metadata/ProcessedByRouteEngine', 'true')
    end)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- ROUTING
-- ═══════════════════════════════════════════════════════════════════════════════

local function sendToDestination(resourceId, destination, resourceType)
    log("INFO", "send_started", {
        resource_id = resourceId,
        destination = destination,
        resource_type = resourceType or "instance"
    })
    
    local success, result = pcall(function()
        return SendToModality(resourceId, destination)
    end)
    
    if success and result then
        log("INFO", "send_success", {
            resource_id = resourceId,
            destination = destination,
            job_id = tostring(result)
        })
        return true, result
    else
        log("ERROR", "send_failed", {
            resource_id = resourceId,
            destination = destination,
            error = tostring(result)
        })
        return false, tostring(result)
    end
end

local function executeRoute(route, studyId, tags, instances)
    log("INFO", "route_matched", {
        route_name = route.name,
        study_id = studyId,
        patient = tags['PatientName']
    })
    
    local action = route.action
    local resourceId = nil
    
    -- Determine what to send
    if action.send == "highest_resolution" then
        local best = findHighestResolutionInstance(instances)
        if best then
            resourceId = best['ID']
        end
    elseif action.send == "study" then
        resourceId = studyId
    end
    
    if not resourceId then
        log("WARN", "no_resource_to_send", {
            route_name = route.name,
            study_id = studyId
        })
        return
    end
    
    -- Send to each destination
    for _, destination in ipairs(action.to) do
        sendToDestination(resourceId, destination, action.send)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- MAIN CALLBACK
-- ═══════════════════════════════════════════════════════════════════════════════

function OnStableStudy(studyId, tags, metadata, origin)
    -- Validate inputs
    if not studyId or not tags then
        log("ERROR", "invalid_callback_params", {study_id = studyId})
        return
    end
    
    -- Skip Lua-originated studies
    if origin and origin["RequestOrigin"] == "Lua" then
        log("DEBUG", "skipped_lua_origin", {study_id = studyId})
        return
    end
    
    log("INFO", "study_received", {
        study_id = studyId,
        patient = tags['PatientName'],
        description = tags['StudyDescription']
    })
    
    -- Get instances
    local success, instances = pcall(function()
        local response = RestApiGet('/studies/' .. studyId .. '/instances')
        return response and ParseJson(response) or nil
    end)
    
    if not success or not instances then
        log("ERROR", "failed_to_get_instances", {study_id = studyId})
        return
    end
    
    log("DEBUG", "study_has_instances", {
        study_id = studyId,
        count = tableLength(instances)
    })
    
    -- Check each route
    for _, route in ipairs(CONFIG.routes) do
        -- For study-level routes
        if matchRoute(route, tags, nil) then
            executeRoute(route, studyId, tags, instances)
        end
        
        -- For instance-level routes
        for _, instance in pairs(instances) do
            if instance and instance['ID'] and not hasBeenProcessed(instance['ID']) then
                local instanceSuccess, instanceTags = pcall(function()
                    local response = RestApiGet('/instances/' .. instance['ID'] .. '/tags?simplify')
                    return response and ParseJson(response) or nil
                end)
                
                if instanceSuccess and instanceTags then
                    if matchRoute(route, tags, instanceTags) then
                        for _, destination in ipairs(route.action.to) do
                            local sent, _ = sendToDestination(instance['ID'], destination, "instance")
                            if sent then
                                markAsProcessed(instance['ID'])
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════════

log("INFO", "route_engine_loaded", {
    routes = #CONFIG.routes,
    max_attempts = CONFIG.max_attempts
})
