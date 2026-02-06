-- ═══════════════════════════════════════════════════════════════════════════════
-- ROUTING TRACKER
-- Helper functions to track routing events in PostgreSQL via the routing-api
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- Usage in your Lua scripts:
--   1. Include this file first: dofile('/etc/orthanc/lua/routing_tracker.lua')
--   2. Call TrackRouting() before SendToModality():
--
--      TrackRouting(studyId, "MERCURE", "sent")
--      SendToModality(studyId, "MERCURE")
--      TrackRouting(studyId, "MERCURE", "success")  -- or "failed" on error
--
-- ═══════════════════════════════════════════════════════════════════════════════

-- Routing API endpoint (internal Docker network)
ROUTING_API_URL = "http://routing-api:5000"

-- Track a routing event
-- @param studyId: Orthanc study ID
-- @param destination: Name of the DICOM modality
-- @param status: "sent", "success", or "failed"
-- @param errorMessage: Optional error message for failures
function TrackRouting(studyId, destination, status, errorMessage)
    local payload = {
        study_id = studyId,
        destination = destination,
        status = status,
        error = errorMessage
    }
    
    -- Make HTTP POST to routing API
    local success, result = pcall(function()
        HttpPost(ROUTING_API_URL .. "/routing/event", DumpJson(payload), {
            ["Content-Type"] = "application/json"
        })
    end)
    
    if not success then
        print("[ROUTING_TRACKER] Warning: Failed to track routing event: " .. tostring(result))
    else
        print("[ROUTING_TRACKER] Recorded: " .. destination .. " -> " .. status)
    end
end

-- Wrapper function that sends to modality and tracks the result
-- @param studyId: Orthanc study ID  
-- @param destination: Name of the DICOM modality
-- @return: true if successful, false otherwise
function SendAndTrack(studyId, destination)
    -- Record that we're sending
    TrackRouting(studyId, destination, "sent")
    
    -- Attempt to send
    local success, result = pcall(function()
        SendToModality(studyId, destination)
    end)
    
    if success then
        TrackRouting(studyId, destination, "success")
        print("[ROUTING_TRACKER] Successfully sent " .. studyId .. " to " .. destination)
        return true
    else
        TrackRouting(studyId, destination, "failed", tostring(result))
        print("[ROUTING_TRACKER] Failed to send " .. studyId .. " to " .. destination .. ": " .. tostring(result))
        return false
    end
end

print("[ROUTING_TRACKER] Loaded routing tracker helper functions")
