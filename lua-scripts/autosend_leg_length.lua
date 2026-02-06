-- ═══════════════════════════════════════════════════════════════════════════════
-- PIPELINE TRACKER - Track study journey through AI processing pipeline
-- ═══════════════════════════════════════════════════════════════════════════════
TRACKING_API = "http://routing-api:5000"

-- Job tracking table: maps job IDs to their context (study_id, destination)
-- This allows us to track actual completion, not just queueing
PendingJobs = {}

-- Start tracking a new study
function TrackStart(studyId, patientName, studyDescription, studyUid)
    pcall(function()
        HttpPost(TRACKING_API .. "/track/start", DumpJson({
            study_id = studyId,
            patient_name = patientName,
            study_description = studyDescription,
            study_uid = studyUid
        }), { ["Content-Type"] = "application/json" })
    end)
    print("[TRACK] Started: " .. studyId)
end

-- Track MERCURE send - now tracks job completion, not just queueing
function TrackMercureSent(studyId, success, errorMsg)
    pcall(function()
        HttpPost(TRACKING_API .. "/track/mercure-sent", DumpJson({
            study_id = studyId,
            success = success,
            error = errorMsg
        }), { ["Content-Type"] = "application/json" })
    end)
    print("[TRACK] MERCURE send: " .. (success and "OK" or "FAILED"))
end

-- Track AI results received back
function TrackAIResultsReceived(studyId)
    pcall(function()
        HttpPost(TRACKING_API .. "/track/ai-results", DumpJson({
            study_id = studyId
        }), { ["Content-Type"] = "application/json" })
    end)
    print("[TRACK] AI results received for: " .. studyId)
end

-- Track destination send result (called on job completion)
function TrackDestination(studyId, destination, success, errorMsg)
    pcall(function()
        HttpPost(TRACKING_API .. "/track/destination", DumpJson({
            study_id = studyId,
            destination = destination,
            success = success,
            error = errorMsg
        }), { ["Content-Type"] = "application/json" })
    end)
    print("[TRACK] " .. destination .. ": " .. (success and "OK" or "FAILED") .. (errorMsg and (" - " .. errorMsg) or ""))
end

-- Register a pending job to track its completion
function RegisterPendingJob(jobId, studyId, destination)
    if jobId then
        PendingJobs[jobId] = {
            study_id = studyId,
            destination = destination,
            queued_at = os.time()
        }
        print("[TRACK] Registered job " .. jobId .. " for " .. destination .. " (study: " .. studyId .. ")")
    end
end

-- Called by Orthanc when a job succeeds
function OnJobSuccess(jobId)
    local job = PendingJobs[jobId]
    if job then
        print("[TRACK] Job " .. jobId .. " SUCCEEDED - " .. job.destination)
        if job.destination == "MERCURE" then
            TrackMercureSent(job.study_id, true, nil)
        else
            TrackDestination(job.study_id, job.destination, true, nil)
        end
        PendingJobs[jobId] = nil
    end
end

-- Called by Orthanc when a job fails
function OnJobFailure(jobId)
    local job = PendingJobs[jobId]
    if job then
        -- Try to get failure reason from Orthanc
        local errorMsg = "Send failed"
        pcall(function()
            local jobInfo = ParseJson(RestApiGet('/jobs/' .. jobId))
            if jobInfo and jobInfo['ErrorDescription'] then
                errorMsg = jobInfo['ErrorDescription']
            elseif jobInfo and jobInfo['Content'] and jobInfo['Content']['Description'] then
                errorMsg = jobInfo['Content']['Description']
            end
        end)
        
        print("[TRACK] Job " .. jobId .. " FAILED - " .. job.destination .. ": " .. errorMsg)
        if job.destination == "MERCURE" then
            TrackMercureSent(job.study_id, false, errorMsg)
        else
            TrackDestination(job.study_id, job.destination, false, errorMsg)
        end
        PendingJobs[jobId] = nil
    end
end

-- Legacy compatibility
function TrackRouting(studyId, destination, status, errorMessage)
    if destination == "MERCURE" then
        TrackMercureSent(studyId, status == "success", errorMessage)
    else
        TrackDestination(studyId, destination, status == "success", errorMessage)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- HELPER FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════════

-- Helper function to safely convert table to string for debugging
function tableToString(t, indent)
    if type(t) ~= "table" then
        return tostring(t)
    end
    
    indent = indent or 0
    local spacing = string.rep("  ", indent)
    local result = "{\n"
    
    for k, v in pairs(t) do
        if type(v) == "table" then
            result = result .. spacing .. "  " .. tostring(k) .. " = " .. tableToString(v, indent + 1) .. ",\n"
        else
            result = result .. spacing .. "  " .. tostring(k) .. " = " .. tostring(v) .. ",\n"
        end
    end
    
    result = result .. spacing .. "}"
    return result
end

-- Helper function to safely get table length
function getTableLength(t)
    if type(t) ~= "table" then
        return 0
    end
    
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count
end

-- Helper function to check if study has already been processed by Stanford AIDE
function hasStanfordAIDEOutput(instances)
    if not instances or type(instances) ~= "table" then
        print('   No instances provided or invalid instances table')
        return false
    end
    
    for _, instance in pairs(instances) do
        if instance and instance['ID'] then
            local success, instanceTags = pcall(function()
                local response = RestApiGet('/instances/' .. instance['ID'] .. '/tags?simplify')
                return response and ParseJson(response) or nil
            end)
            
            if success and instanceTags then
                -- Primary check: Stanford AIDE manufacturer
                local manufacturer = instanceTags['Manufacturer'] or ''
                if string.upper(manufacturer) == 'STANFORDAIDE' then
                    print('   Found Stanford AIDE output (Manufacturer: ' .. manufacturer .. ')')
                    return true
                end
                
                -- Secondary check: Structured Report modality (AI outputs)
                local modality = instanceTags['Modality'] or ''
                if modality == 'SR' then
                    print('   Found Structured Report output (Modality: SR)')
                    return true
                end
                
                -- Tertiary check: AI-specific series descriptions
                local seriesDescription = instanceTags['SeriesDescription'] or ''
                local upperSeriesDesc = string.upper(seriesDescription)
                if string.find(upperSeriesDesc, 'AI MEASUREMENTS') or 
                   string.find(upperSeriesDesc, 'QA VISUALIZATION') then
                    print('   Found AI-specific series description: ' .. seriesDescription)
                    return true
                end
                
                -- Quaternary check: Software version pattern
                local softwareVersions = instanceTags['SoftwareVersions'] or ''
                if string.find(string.upper(softwareVersions), 'PEDIATRIC_LEG_LENGTH_V') then
                    print('   Found AI software version: ' .. softwareVersions)
                    return true
                end
                
                -- Final check: Institution/Station/Department combination indicating AI processing
                local institutionName = instanceTags['InstitutionName'] or ''
                local department = instanceTags['InstitutionalDepartmentName'] or ''
                local stationName = instanceTags['StationName'] or ''
                
                if string.upper(institutionName) == 'SOM' and 
                   string.upper(department) == 'RADIOLOGY' and 
                   string.upper(stationName) == 'LPCH' and
                   string.upper(manufacturer) == 'STANFORDAIDE' then
                    print('   Found Stanford AIDE institutional pattern')
                    return true
                end
            else
                print('   Failed to retrieve tags for instance: ' .. tostring(instance['ID']))
            end
        else
            print('   Invalid instance found (missing ID)')
        end
    end
    return false
end

-- Helper function to find the instance with the highest matrix size
function findHighestResolutionInstance(instances)
    if not instances or type(instances) ~= "table" then
        print('   No instances provided or invalid instances table')
        return nil
    end
    
    local bestInstance = nil
    local maxMatrixSize = 0
    local instanceCount = getTableLength(instances)
    
    print('   Analyzing matrix sizes across ' .. instanceCount .. ' instances:')
    
    local i = 0
    for _, instance in pairs(instances) do
        i = i + 1
        
        if instance and instance['ID'] then
            local success, instanceTags = pcall(function()
                local response = RestApiGet('/instances/' .. instance['ID'] .. '/tags?simplify')
                return response and ParseJson(response) or nil
            end)
            
            if success and instanceTags then
                -- Get matrix dimensions
                local rows = tonumber(instanceTags['Rows'] or '0') or 0
                local columns = tonumber(instanceTags['Columns'] or '0') or 0
                local matrixSize = rows * columns
                
                -- Get additional info for logging
                local seriesDescription = instanceTags['SeriesDescription'] or 'Unknown'
                local instanceNumber = instanceTags['InstanceNumber'] or 'Unknown'
                
                print('      Instance ' .. i .. ': ' .. rows .. 'x' .. columns .. ' (' .. matrixSize .. ' pixels) - ' .. 
                      seriesDescription .. ' [#' .. instanceNumber .. ']')
                
                -- Update best instance if this one has higher resolution
                if matrixSize > maxMatrixSize then
                    maxMatrixSize = matrixSize
                    bestInstance = instance
                    print('         ^ New highest resolution found')
                end
            else
                print('      Instance ' .. i .. ': Could not retrieve tags for ID: ' .. tostring(instance['ID']))
            end
        else
            print('      Instance ' .. i .. ': Invalid instance (missing ID)')
        end
    end
    
    if bestInstance then
        local success, bestTags = pcall(function()
            local response = RestApiGet('/instances/' .. bestInstance['ID'] .. '/tags?simplify')
            return response and ParseJson(response) or nil
        end)
        
        if success and bestTags then
            local bestRows = bestTags['Rows'] or '0'
            local bestColumns = bestTags['Columns'] or '0'
            local bestSeries = bestTags['SeriesDescription'] or 'Unknown'
            print('   Selected highest resolution: ' .. bestRows .. 'x' .. bestColumns .. ' (' .. maxMatrixSize .. ' pixels) - ' .. bestSeries)
        end
    else
        print('   Warning: No valid instance found with matrix dimensions')
    end
    
    return bestInstance
end

-- New function to check if an instance has been processed
function hasBeenProcessed(instanceId)
    local metadata = ParseJson(RestApiGet('/instances/' .. instanceId .. '/metadata'))
    return metadata['ProcessedByLua'] == 'true'
end

-- New function to mark an instance as processed
function markAsProcessed(instanceId)
    RestApiPut('/instances/' .. instanceId .. '/metadata/ProcessedByLua', 'true')
end

function OnStableStudy(studyId, tags, metadata, origin)
    -- Safe parameter validation
    if not studyId then
        print('Error: studyId is nil')
        return
    end
    
    if not tags then
        print('Error: tags is nil')
        return
    end

    print('OnStableStudy called for studyId: ' .. tostring(studyId))
    print('Tags: ' .. tableToString(tags))
    print('Metadata: ' .. tableToString(metadata))
    print('Origin: ' .. tableToString(origin))

    -- Avoid processing our own modifications
    if origin and origin["RequestOrigin"] == "Lua" then
        print('Skipping processing of Lua-originated study')
        return
    end

    -- Get instances for this study
    local success, instances = pcall(function()
        local response = RestApiGet('/studies/' .. studyId .. '/instances')
        return response and ParseJson(response) or nil
    end)
    
    if not success or not instances then
        print('Failed to retrieve instances for study: ' .. studyId)
        return
    end

    -- Check if study description matches bone length studies
    local studyDescription = tags['StudyDescription'] or ''
    local normalizedDescription = string.upper(studyDescription)
    local isBoneLengthStudy = string.find(normalizedDescription, 'EXTREMITY BILATERAL BONE LENGTH') ~= nil
    
    if not isBoneLengthStudy then
        print('Not a bone length study, ignoring')
        return
    end
    
    print('📋 Detected bone length study')
    
    -- Check if this study has Stanford AIDE output (already processed)
    local hasAIDEOutput = hasStanfordAIDEOutput(instances)
    
    if hasAIDEOutput then
        print('   ✓ Study contains Stanford AIDE output - routing to final destinations')
        -- Track that AI results have been received
        TrackAIResultsReceived(studyId)
        
        -- Route Stanford AIDE outputs to their destinations
        for _, instance in pairs(instances) do
            if instance and instance['ID'] then
                -- Check if this instance has already been processed
                if hasBeenProcessed(instance['ID']) then
                    print('   ⏭ Instance ' .. instance['ID'] .. ' already processed and routed, skipping')
                else
                    local success, instanceTags = pcall(function()
                        local response = RestApiGet('/instances/' .. instance['ID'] .. '/tags?simplify')
                        return response and ParseJson(response) or nil
                    end)
                    
                    if success and instanceTags then
                        local seriesDescription = instanceTags['SeriesDescription'] or ''
                        local modality = instanceTags['Modality'] or ''
                        local manufacturer = instanceTags['Manufacturer'] or ''
                        
                        print('   Analyzing instance: ' .. instance['ID'])
                        print('      Manufacturer: ' .. manufacturer)
                        print('      Modality: ' .. modality)
                        print('      Series Description: ' .. seriesDescription)
                        
                        -- Route QA Visualization to DICOM QA routers (exact match only, not QA Table Visualization)
                        local upperSeriesDesc = string.upper(seriesDescription)
                        if string.find(upperSeriesDesc, 'QA VISUALIZATION') and 
                           not string.find(upperSeriesDesc, 'TABLE') then
                            print('   ✓ Detected QA Visualization - routing to LPCHROUTER and LPCHTROUTER')
                            
                            -- Route to LPCHROUTER (track on job completion)
                            local success1, job1 = pcall(function()
                                return SendToModality(instance['ID'], 'LPCHROUTER')
                            end)
                            
                            if success1 and job1 then
                                print('      ⏳ Queued to LPCHROUTER (Job: ' .. tostring(job1) .. ') - tracking completion...')
                                RegisterPendingJob(job1, studyId, 'LPCHROUTER')
                            else
                                print('      ✗ FAILED to queue to LPCHROUTER - Error: ' .. tostring(job1))
                                TrackDestination(studyId, 'LPCHROUTER', false, 'Failed to queue: ' .. tostring(job1))
                            end
                            
                            -- Route to LPCHTROUTER (track on job completion)
                            local success2, job2 = pcall(function()
                                return SendToModality(instance['ID'], 'LPCHTROUTER')
                            end)
                            
                            if success2 and job2 then
                                print('      ⏳ Queued to LPCHTROUTER (Job: ' .. tostring(job2) .. ') - tracking completion...')
                                RegisterPendingJob(job2, studyId, 'LPCHTROUTER')
                            else
                                print('      ✗ FAILED to queue to LPCHTROUTER - Error: ' .. tostring(job2))
                                TrackDestination(studyId, 'LPCHTROUTER', false, 'Failed to queue: ' .. tostring(job2))
                            end
                            
                            -- Mark as processed after routing
                            local markSuccess = pcall(function()
                                markAsProcessed(instance['ID'])
                            end)
                            if markSuccess then
                                print('      ✓ Instance marked as processed')
                            else
                                print('      ⚠ Could not mark instance as processed (instance may have been moved/deleted)')
                            end
                        
                        -- Route Structured Reports to MODLINK
                        elseif modality == 'SR' then
                            print('   ✓ Detected Structured Report - routing to MODLINK')
                            
                            -- Route to MODLINK (track on job completion)
                            local success1, job1 = pcall(function()
                                return SendToModality(instance['ID'], 'MODLINK')
                            end)
                            
                            if success1 and job1 then
                                print('      ⏳ Queued to MODLINK (Job: ' .. tostring(job1) .. ') - tracking completion...')
                                RegisterPendingJob(job1, studyId, 'MODLINK')
                            else
                                print('      ✗ FAILED to queue to MODLINK - Error: ' .. tostring(job1))
                                TrackDestination(studyId, 'MODLINK', false, 'Failed to queue: ' .. tostring(job1))
                            end
                            
                            -- Mark as processed after routing
                            local markSuccess = pcall(function()
                                markAsProcessed(instance['ID'])
                            end)
                            if markSuccess then
                                print('      ✓ Instance marked as processed')
                            else
                                print('      ⚠ Could not mark instance as processed (instance may have been moved/deleted)')
                            end
                        else
                            print('      ℹ Instance does not require routing (not QA Visualization or SR)')
                        end
                    else
                        print('   ✗ FAILED to retrieve tags for instance: ' .. tostring(instance['ID']))
                    end
                end
            end
        end
        
        print('   ✓ Stanford AIDE output routing complete - NOT re-sending to MERCURE')
        return
    end
    
    -- Original study (no Stanford AIDE output yet) - send to MERCURE for processing
    local patientName = tags['PatientName'] or 'Unknown'
    local studyInstanceUID = tags['StudyInstanceUID'] or 'Unknown'
    
    print('🦴 PROCESSING NEW BONE LENGTH STUDY (No AIDE output detected)')
    print('   Study ID: ' .. studyId)
    print('   Patient: ' .. patientName)
    print('   Study UID: ' .. studyInstanceUID)
    print('   Original Description: ' .. studyDescription)
    print('   Found ' .. getTableLength(instances) .. ' instances in study')
    
    -- Start pipeline tracking
    TrackStart(studyId, patientName, studyDescription, studyInstanceUID)
    
    local bestInstance = findHighestResolutionInstance(instances)
    
    if bestInstance then
        local success, job = pcall(function()
            return SendToModality(bestInstance['ID'], 'MERCURE')
        end)
        
        if success and job then
            print('   ⏳ Highest resolution instance queued for MERCURE (Job: ' .. tostring(job) .. ') - tracking completion...')
            print('AUTO-FORWARD: Bone length study (highest res) queued to MERCURE - Patient: ' .. 
                      patientName .. ', Study: ' .. studyId .. ', Job: ' .. tostring(job))
            -- Track on job completion, not now
            RegisterPendingJob(job, studyId, 'MERCURE')
        else
            print('   ✗ FAILED to queue highest resolution instance to MERCURE - Error: ' .. tostring(job))
            print('AUTO-FORWARD FAILED: Could not queue to MERCURE - Study: ' .. studyId)
            TrackMercureSent(studyId, false, 'Failed to queue: ' .. tostring(job))
        end
    else
        print('   ⚠ No valid instance found with matrix dimensions')
        print('AUTO-FORWARD FAILED: No valid high-resolution instance found - Study: ' .. studyId)
    end
end