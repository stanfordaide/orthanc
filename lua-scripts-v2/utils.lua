-- ═══════════════════════════════════════════════════════════════════════════════
-- RADWATCH ROUTING - UTILITIES
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- PURPOSE:
--   Small helper functions used throughout the codebase.
--   No business logic here - just general utilities.
--
-- USAGE:
--   local Utils = dofile('/path/to/utils.lua')
--   local upper = Utils.upper("hello")  -- "HELLO"
--   local safe = Utils.safeGet(tags, "PatientName", "Unknown")
--
-- ═══════════════════════════════════════════════════════════════════════════════

local Utils = {}

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 1: STRING HELPERS
-- ─────────────────────────────────────────────────────────────────────────────────

-- Convert string to uppercase (nil-safe)
function Utils.upper(str)
    if str == nil then return "" end
    return string.upper(tostring(str))
end

-- Convert string to lowercase (nil-safe)
function Utils.lower(str)
    if str == nil then return "" end
    return string.lower(tostring(str))
end

-- Trim whitespace from both ends
function Utils.trim(str)
    if str == nil then return "" end
    return tostring(str):match("^%s*(.-)%s*$")
end

-- Check if string contains pattern (case-insensitive)
function Utils.containsIgnoreCase(str, pattern)
    if str == nil or pattern == nil then return false end
    return Utils.upper(str):find(Utils.upper(pattern)) ~= nil
end

-- Check if string matches any pattern in a list (case-insensitive)
function Utils.matchesAny(str, patterns)
    if str == nil or patterns == nil then return false, nil end
    
    local upperStr = Utils.upper(str)
    for _, pattern in ipairs(patterns) do
        if upperStr:find(Utils.upper(pattern)) then
            return true, pattern
        end
    end
    return false, nil
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 2: TABLE/OBJECT HELPERS  
-- ─────────────────────────────────────────────────────────────────────────────────

-- Safely get a value from a table (with default)
-- Utils.safeGet(tags, "PatientName", "Unknown") 
function Utils.safeGet(tbl, key, default)
    if tbl == nil then return default end
    local value = tbl[key]
    if value == nil or value == "" then return default end
    return value
end

-- Safely get a nested value
-- Utils.safeGetNested(study, {"MainDicomTags", "StudyDescription"}, "")
function Utils.safeGetNested(tbl, keys, default)
    if tbl == nil or keys == nil then return default end
    
    local current = tbl
    for _, key in ipairs(keys) do
        if current == nil or type(current) ~= "table" then
            return default
        end
        current = current[key]
    end
    
    if current == nil or current == "" then return default end
    return current
end

-- Check if table is empty
function Utils.isEmpty(tbl)
    if tbl == nil then return true end
    return next(tbl) == nil
end

-- Get table length (works for any table, not just arrays)
function Utils.tableLength(tbl)
    if tbl == nil then return 0 end
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    return count
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 3: PROTECTED CALLS
-- ─────────────────────────────────────────────────────────────────────────────────
-- Safely call functions that might error

-- Call a function and catch errors
-- Returns: success (bool), result or error message
function Utils.try(func, ...)
    local args = {...}
    local success, result = pcall(function()
        return func(table.unpack(args))
    end)
    return success, result
end

-- Call a function, return default if it errors
function Utils.tryOr(func, default, ...)
    local success, result = Utils.try(func, ...)
    if success then
        return result
    else
        return default
    end
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 4: JSON HELPERS
-- ─────────────────────────────────────────────────────────────────────────────────
-- Note: Orthanc provides global JsonEncode and ParseJson functions

-- Safely encode to JSON
-- NOTE: Use DumpJson (not JsonEncode) - it's what the original script uses and doesn't crash
function Utils.toJson(tbl)
    if tbl == nil then return "{}" end
    
    -- Try DumpJson first (Orthanc's built-in, used by original script)
    local success, result = pcall(function()
        return DumpJson(tbl)
    end)
    
    if success and result then
        return result
    end
    
    -- Fallback: Manual JSON encoding for simple flat tables
    local parts = {}
    for key, value in pairs(tbl) do
        local keyStr = '"' .. tostring(key) .. '"'
        local valueStr
        
        if value == nil then
            valueStr = "null"
        elseif type(value) == "boolean" then
            valueStr = value and "true" or "false"
        elseif type(value) == "number" then
            valueStr = tostring(value)
        elseif type(value) == "string" then
            -- Escape special characters in strings
            local escaped = value:gsub('\\', '\\\\')
                                 :gsub('"', '\\"')
                                 :gsub('\n', '\\n')
                                 :gsub('\r', '\\r')
                                 :gsub('\t', '\\t')
            valueStr = '"' .. escaped .. '"'
        else
            -- For other types (tables, functions, etc), convert to string
            valueStr = '"' .. tostring(value) .. '"'
        end
        
        table.insert(parts, keyStr .. ":" .. valueStr)
    end
    
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Safely parse JSON
function Utils.fromJson(str)
    if str == nil or str == "" then return nil end
    local success, result = pcall(function()
        return ParseJson(str)  -- Orthanc built-in
    end)
    if success then
        return result
    else
        return nil
    end
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 5: HTTP HELPERS
-- ─────────────────────────────────────────────────────────────────────────────────
-- For calling external APIs

-- Make an HTTP POST request
-- Returns: success (bool), response body or error
-- NOTE: Orthanc's HttpPost takes (url, body, headers_table)
function Utils.httpPost(url, body)
    local success, result = pcall(function()
        -- Orthanc's built-in HTTP function for external calls
        -- Must include Content-Type header for JSON
        return HttpPost(url, body, { ["Content-Type"] = "application/json" })
    end)
    
    return success, result
end

-- Make an HTTP GET request
-- NOTE: Orthanc doesn't have HttpGet, so we use HttpPost with empty body
-- For internal Orthanc API calls, use RestApiGet instead
function Utils.httpGet(url)
    local success, result = pcall(function()
        -- Use POST with empty body as workaround (some APIs accept this for health checks)
        return HttpPost(url, "", "application/json")
    end)
    return success, result
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 6: DICOM TAG HELPERS
-- ─────────────────────────────────────────────────────────────────────────────────
-- Working with DICOM tags

-- Extract common tags into a simple table
function Utils.extractCommonTags(tags)
    return {
        patientName = Utils.safeGet(tags, "PatientName", "Unknown"),
        patientId = Utils.safeGet(tags, "PatientID", ""),
        studyDescription = Utils.safeGet(tags, "StudyDescription", ""),
        seriesDescription = Utils.safeGet(tags, "SeriesDescription", ""),
        modality = Utils.safeGet(tags, "Modality", ""),
        studyDate = Utils.safeGet(tags, "StudyDate", ""),
        studyInstanceUid = Utils.safeGet(tags, "StudyInstanceUID", ""),
        seriesInstanceUid = Utils.safeGet(tags, "SeriesInstanceUID", ""),
        rows = tonumber(Utils.safeGet(tags, "Rows", 0)) or 0,
        columns = tonumber(Utils.safeGet(tags, "Columns", 0)) or 0,
    }
end

-- Calculate image matrix size (Rows × Columns)
function Utils.getMatrixSize(tags)
    local rows = tonumber(Utils.safeGet(tags, "Rows", 0)) or 0
    local cols = tonumber(Utils.safeGet(tags, "Columns", 0)) or 0
    return rows * cols
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- SECTION 7: DEBUGGING
-- ─────────────────────────────────────────────────────────────────────────────────

-- Print a table for debugging (not for production logs)
function Utils.dump(tbl, indent)
    indent = indent or 0
    local spaces = string.rep("  ", indent)
    
    if tbl == nil then
        print(spaces .. "nil")
        return
    end
    
    if type(tbl) ~= "table" then
        print(spaces .. tostring(tbl))
        return
    end
    
    for key, value in pairs(tbl) do
        if type(value) == "table" then
            print(spaces .. tostring(key) .. ":")
            Utils.dump(value, indent + 1)
        else
            print(spaces .. tostring(key) .. " = " .. tostring(value))
        end
    end
end

-- ─────────────────────────────────────────────────────────────────────────────────
-- RETURN THE UTILS MODULE
-- ─────────────────────────────────────────────────────────────────────────────────

return Utils
