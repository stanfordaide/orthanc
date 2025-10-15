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

    -- Check if this is a result from MERCURE
    if origin and origin["RequestOrigin"] == "Dicom" and origin["RemoteAet"] == "MERCURE" then
        print('Received study from MERCURE, processing for routing')
        
        local success, instances = pcall(function()
            local response = RestApiGet('/studies/' .. studyId .. '/instances')
            return response and ParseJson(response) or nil
        end)
        
        if not success or not instances then
            print('Failed to retrieve instances for study: ' .. studyId)
            return
        end
        
        for _, instance in pairs(instances) do
            if not hasBeenProcessed(instance['ID']) then
                local success, instanceTags = pcall(function()
                    local response = RestApiGet('/instances/' .. instance['ID'] .. '/tags?simplify')
                    return response and ParseJson(response) or nil
                end)
                
                if success and instanceTags then
                    local seriesDescription = instanceTags['SeriesDescription'] or ''
                    local modality = instanceTags['Modality'] or ''
                    
                    if string.find(string.upper(seriesDescription), 'QA VISUALIZATION') then
                        print('Routing QA Visualization to LPCHROUTER and LPCHTROUTER')
                        SendToModality(instance['ID'], 'LPCHROUTER')
                        SendToModality(instance['ID'], 'LPCHTROUTER')
                        markAsProcessed(instance['ID'])
                    elseif modality == 'SR' then
                        print('Routing Structured Report to MODLINK')
                        SendToModality(instance['ID'], 'MODLINK')
                        markAsProcessed(instance['ID'])
                    else
                        print('Unhandled instance type: ' .. seriesDescription .. ' (Modality: ' .. modality .. ')')
                    end
                else
                    print('Failed to retrieve tags for instance: ' .. tostring(instance['ID']))
                end
            else
                print('Instance ' .. instance['ID'] .. ' has already been processed, skipping')
            end
        end
    else
        -- Original processing for incoming bone length studies
        local studyDescription = tags['StudyDescription'] or ''
        local normalizedDescription = string.upper(studyDescription)
        
        if string.find(normalizedDescription, 'EXTREMITY BILATERAL BONE LENGTH') then
            local success, instances = pcall(function()
                local response = RestApiGet('/studies/' .. studyId .. '/instances')
                return response and ParseJson(response) or nil
            end)
            
            if not success or not instances then
                print('   Failed to retrieve instances for study: ' .. studyId)
                return
            end
            
            if hasStanfordAIDEOutput(instances) then
                print('   Study already processed by Stanford AIDE, skipping')
                return
            end

            local patientName = tags['PatientName'] or 'Unknown'
            local studyInstanceUID = tags['StudyInstanceUID'] or 'Unknown'
            
            print('🦴 PROCESSING NEW BONE LENGTH STUDY')
            print('   Study ID: ' .. studyId)
            print('   Patient: ' .. patientName)
            print('   Study UID: ' .. studyInstanceUID)
            print('   Original Description: ' .. studyDescription)
            print('   Found ' .. getTableLength(instances) .. ' instances in study')
            
            local bestInstance = findHighestResolutionInstance(instances)
            
            if bestInstance then
                local success, job = pcall(function()
                    return SendToModality(bestInstance['ID'], 'MERCURE')
                end)
                
                if success and job then
                    print('   ✓ Highest resolution instance queued for MERCURE (Job: ' .. tostring(job) .. ')')
                    print('AUTO-FORWARD: Bone length study (highest res) forwarded to MERCURE - Patient: ' .. 
                              patientName .. ', Study: ' .. studyId .. ', Job: ' .. tostring(job))
                else
                    print('   ✗ Failed to queue highest resolution instance')
                    print('AUTO-FORWARD FAILED: Could not send highest resolution instance - Study: ' .. studyId)
                end
            else
                print('   ⚠ No valid instance found with matrix dimensions')
                print('AUTO-FORWARD FAILED: No valid high-resolution instance found - Study: ' .. studyId)
            end
        end
    end
end