-- ═══════════════════════════════════════════════════════════════════════════════
-- ROUTING STATE TABLE
-- ═══════════════════════════════════════════════════════════════════════════════
-- This table tracks the routing status of studies to DICOM destinations.
-- It enables retry logic, stuck study detection, and routing history.
--
-- This script runs automatically on first PostgreSQL startup.
-- ═══════════════════════════════════════════════════════════════════════════════

-- Only create if not exists (idempotent)
CREATE TABLE IF NOT EXISTS routing_state (
    id                  SERIAL PRIMARY KEY,
    
    -- Study identification
    study_id            VARCHAR(64) NOT NULL,      -- Orthanc study ID
    study_uid           VARCHAR(128),              -- DICOM StudyInstanceUID
    patient_name        VARCHAR(256),
    patient_id          VARCHAR(64),
    study_description   VARCHAR(256),
    study_date          DATE,
    
    -- Routing target
    destination         VARCHAR(64) NOT NULL,      -- DICOM modality name
    route_name          VARCHAR(128),              -- Which route rule triggered this
    
    -- State tracking
    -- Values: 'pending', 'sending', 'sent', 'success', 'failed', 'stuck', 'skipped', 'cancelled'
    status              VARCHAR(20) NOT NULL DEFAULT 'pending',
    
    -- Job tracking
    job_id              VARCHAR(64),               -- Orthanc job ID
    job_status          VARCHAR(20),               -- pending, running, success, failure
    
    -- Retry tracking
    attempt_count       INTEGER DEFAULT 0,
    max_attempts        INTEGER DEFAULT 3,
    next_retry_at       TIMESTAMP,
    
    -- Error tracking
    last_error          TEXT,
    last_error_at       TIMESTAMP,
    
    -- Timestamps
    created_at          TIMESTAMP DEFAULT NOW(),
    updated_at          TIMESTAMP DEFAULT NOW(),
    completed_at        TIMESTAMP,
    
    -- Ensure one record per study-destination pair
    UNIQUE(study_id, destination)
);

-- ═══════════════════════════════════════════════════════════════════════════════
-- INDEXES
-- ═══════════════════════════════════════════════════════════════════════════════

-- Fast lookup by status (for finding stuck, pending, failed)
CREATE INDEX IF NOT EXISTS idx_routing_state_status 
    ON routing_state(status);

-- Fast lookup by study
CREATE INDEX IF NOT EXISTS idx_routing_state_study 
    ON routing_state(study_id);

-- Fast lookup by destination
CREATE INDEX IF NOT EXISTS idx_routing_state_destination 
    ON routing_state(destination);

-- Fast lookup for retry scheduler
CREATE INDEX IF NOT EXISTS idx_routing_state_next_retry 
    ON routing_state(next_retry_at) 
    WHERE status = 'failed';

-- Fast lookup by creation time (for recent activity)
CREATE INDEX IF NOT EXISTS idx_routing_state_created 
    ON routing_state(created_at DESC);

-- Patient search
CREATE INDEX IF NOT EXISTS idx_routing_state_patient 
    ON routing_state(patient_name);

-- ═══════════════════════════════════════════════════════════════════════════════
-- HELPER FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════════

-- Function to update the updated_at timestamp automatically
CREATE OR REPLACE FUNCTION update_routing_state_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop trigger if exists and recreate
DROP TRIGGER IF EXISTS trigger_routing_state_updated ON routing_state;

CREATE TRIGGER trigger_routing_state_updated
    BEFORE UPDATE ON routing_state
    FOR EACH ROW
    EXECUTE FUNCTION update_routing_state_timestamp();

-- ═══════════════════════════════════════════════════════════════════════════════
-- VIEWS
-- ═══════════════════════════════════════════════════════════════════════════════

-- View for stuck studies (easy query from UI)
CREATE OR REPLACE VIEW stuck_studies AS
SELECT 
    study_id,
    study_uid,
    patient_name,
    patient_id,
    study_description,
    destination,
    attempt_count,
    last_error,
    last_error_at,
    created_at
FROM routing_state
WHERE status = 'stuck'
ORDER BY created_at DESC;

-- View for routing statistics per destination
CREATE OR REPLACE VIEW routing_stats AS
SELECT 
    destination,
    COUNT(*) FILTER (WHERE status = 'success') as success_count,
    COUNT(*) FILTER (WHERE status = 'failed') as failed_count,
    COUNT(*) FILTER (WHERE status = 'stuck') as stuck_count,
    COUNT(*) FILTER (WHERE status = 'pending') as pending_count,
    COUNT(*) FILTER (WHERE status = 'sending' OR status = 'sent') as in_progress_count,
    COUNT(*) as total_count,
    AVG(EXTRACT(EPOCH FROM (completed_at - created_at))) FILTER (WHERE status = 'success') as avg_duration_seconds
FROM routing_state
GROUP BY destination;

-- View for recent activity (last 24 hours)
CREATE OR REPLACE VIEW recent_routing AS
SELECT 
    rs.*,
    CASE 
        WHEN status = 'success' THEN '✅'
        WHEN status = 'failed' THEN '❌'
        WHEN status = 'stuck' THEN '🚨'
        WHEN status = 'pending' THEN '⏳'
        WHEN status IN ('sending', 'sent') THEN '📤'
        WHEN status = 'skipped' THEN '⏭️'
        ELSE '?'
    END as status_icon
FROM routing_state rs
WHERE created_at > NOW() - INTERVAL '24 hours'
ORDER BY created_at DESC;

-- ═══════════════════════════════════════════════════════════════════════════════
-- COMPLETION
-- ═══════════════════════════════════════════════════════════════════════════════

-- Log that initialization completed
DO $$
BEGIN
    RAISE NOTICE 'Routing state table initialized successfully';
END $$;
