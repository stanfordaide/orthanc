-- Helper function to check if study has already been processed by Stanford AIDE
function hasStanfordAIDEOutput(instances)
    for _, instance in pairs(instances) do
        local instanceTags = ParseJson(RestApiGet('/instances/' .. instance['ID'] .. '/tags?simplify'))
        if instanceTags then
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
        end
    end
    return false
end

-- Helper function to find the instance with the highest matrix size
function findHighestResolutionInstance(instances)
    local bestInstance = nil
    local maxMatrixSize = 0
    
    print('   Analyzing matrix sizes across ' .. #instances .. ' instances:')
    
    for i, instance in pairs(instances) do
        local instanceTags = ParseJson(RestApiGet('/instances/' .. instance['ID'] .. '/tags?simplify'))
        if instanceTags then
            -- Get matrix dimensions
            local rows = tonumber(instanceTags['Rows'] or '0')
            local columns = tonumber(instanceTags['Columns'] or '0')
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
            print('      Instance ' .. i .. ': Could not retrieve tags')
        end
    end
    
    if bestInstance then
        local bestTags = ParseJson(RestApiGet('/instances/' .. bestInstance['ID'] .. '/tags?simplify'))
        local bestRows = bestTags['Rows'] or '0'
        local bestColumns = bestTags['Columns'] or '0'
        local bestSeries = bestTags['SeriesDescription'] or 'Unknown'
        print('   Selected highest resolution: ' .. bestRows .. 'x' .. bestColumns .. ' (' .. maxMatrixSize .. ' pixels) - ' .. bestSeries)
    else
        print('   Warning: No valid instance found with matrix dimensions')
    end
    
    return bestInstance
end

function OnStableStudy(studyId, tags, metadata, origin)

    print('OnStableStudy called for studyId: ' .. studyId)
    print('Tags: ' .. table.show(tags))
    print('Metadata: ' .. table.show(metadata))
    print('Origin: ' .. table.show(origin))

    -- Avoid processing our own modifications
    if origin and origin["RequestOrigin"] == "Lua" then
        print('Skipping processing of Lua-originated study')
        return
    end

    local studyDescription = tags['StudyDescription'] or ''
    
    -- Convert to uppercase for case-insensitive comparison
    local normalizedDescription = string.upper(studyDescription)
    
    -- Check if this is a bone length study (relaxed condition)
    -- Matches either "XR EXTREMITY BILATERAL BONE LENGTH" or "LPCH XR EXTREMITY BILATERAL BONE LENGTH"
    if string.find(normalizedDescription, 'EXTREMITY BILATERAL BONE LENGTH') then
        -- Get all instances in the study
        local instances = ParseJson(RestApiGet('/studies/' .. studyId .. '/instances'))
        
        -- Check if already processed by Stanford AIDE
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
        print('   Found ' .. #instances .. ' instances in study')
        
        -- Find the instance with the highest matrix size
        local bestInstance = findHighestResolutionInstance(instances)
        
        if bestInstance then
            -- Send only the highest resolution instance
            local job = SendToModality(bestInstance['ID'], 'MERCURE')
            if job then
                print('   ✓ Highest resolution instance queued for MERCURE (Job: ' .. job .. ')')
                print('AUTO-FORWARD: Bone length study (highest res) forwarded to MERCURE - Patient: ' .. 
                          patientName .. ', Study: ' .. studyId .. ', Job: ' .. job)
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