# RADWATCH Lua Routing Scripts (v2)

## Overview

This folder contains the refactored Lua routing scripts for Orthanc.
The goal is clean, maintainable, observable routing logic.

## File Structure (Planned)

```
lua-scripts-v2/
├── README.md           ← You are here
├── config.lua          ← [DONE] All configuration in one place
├── logger.lua          ← [DONE] Logging utilities
├── utils.lua           ← [DONE] Shared helper functions
├── tracker.lua         ← [DONE] API calls to track workflow state
├── matcher.lua         ← [DONE] Study matching logic
├── router.lua          ← [DONE] Send logic and instance selection
└── main.lua            ← [DONE] Entry point - ties everything together

ALL FILES COMPLETE! ✓
```

## How Orthanc Loads Lua

Orthanc looks for Lua scripts in the path specified by `LuaScripts` in `orthanc.json`.
Currently: `["/etc/orthanc/lua/autosend_leg_length.lua"]`

To use these new scripts, you would change it to:
```json
"LuaScripts": ["/etc/orthanc/lua-v2/main.lua"]
```

And mount the folder in docker-compose.yml:
```yaml
volumes:
  - ./lua-scripts-v2:/etc/orthanc/lua-v2:ro
```

**Don't change this yet** - we'll do it when the new scripts are ready.

---

## Your Tasks

### Current File: `config.lua`

This file is complete but needs your review. Open it and complete these tasks:

#### TASK 1: Review Matching Patterns
- [ ] Verify `BONE_LENGTH_PATTERNS` match your actual study descriptions
- [ ] Confirm `AI_RESULT_PATTERN` ("STANFORD AIDE") is correct
- [ ] Check if any patterns are missing

**How to check:**
```bash
# SSH into the VM, then:
docker exec -it orthanc-postgres psql -U orthanc -d orthanc

# In psql:
SELECT DISTINCT "MainDicomTags"->>'StudyDescription' 
FROM studies 
WHERE "MainDicomTags"->>'StudyDescription' IS NOT NULL
ORDER BY 1;
```

#### TASK 2: Decide on Retry Strategy
- [ ] Should sends retry automatically? (yes/no)
- [ ] If yes, how many times? (currently: 3)
- [ ] How long to wait between retries? (currently: 60s, 120s, 240s)

#### TASK 3: Review Feature Flags
- [ ] Do you need a "dry run" mode?
- [ ] Should destinations be individually toggleable?
- [ ] What happens if tracking API is down?

---

## Next Steps

Once you've reviewed `config.lua`, we'll create:

1. **`logger.lua`** - Consistent logging with levels
2. **`utils.lua`** - Small helper functions
3. **`tracker.lua`** - API calls to routing-api
4. **`matcher.lua`** - Study matching logic
5. **`router.lua`** - Send logic
6. **`main.lua`** - Ties it all together

Each file will follow the same pattern:
- Clear section headers
- TODO markers for your decisions
- Comments explaining the "why"

---

## Testing Plan

Before switching to the new scripts:

1. **Unit test** each function in isolation (we'll create test.lua)
2. **Integration test** with a test study
3. **Shadow mode** - run both old and new, compare logs
4. **Cutover** - switch to new scripts
5. **Rollback plan** - keep old scripts, easy to switch back

---

## Questions?

If anything is unclear, ask before proceeding. 
It's better to understand than to rush.
