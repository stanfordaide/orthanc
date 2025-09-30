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

function OnStableStudy(studyId, tags, metadata, origin)
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
    if string.find(normalizedDescription, 'XR EXTREMITY BILATERAL BONE LENGTH') then
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
        
        -- Process all instances
        local success = true
        local lastJob = nil
        
        for i, instance in pairs(instances) do
            local job = SendToModality(instance['ID'], 'MERCURE')
            if job then
                print('   ✓ Instance ' .. i .. ' queued for MERCURE (Job: ' .. job .. ')')
                lastJob = job
            else
                print('   ✗ Failed to queue instance ' .. i)
                success = false
            end
        end
        
        if success then
            print('   ✓ All instances queued for MERCURE')
            print('AUTO-FORWARD: Bone length study forwarded to MERCURE - Patient: ' .. 
                      patientName .. ', Study: ' .. studyId .. ', Last Job: ' .. lastJob)
        else
            print('   ⚠ Failed to queue some instances')
            print('AUTO-FORWARD PARTIAL: Some instances failed to send - Study: ' .. studyId)
        end
    end
end