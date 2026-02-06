"""
Orthanc Routing Workflow Tracker
Tracks studies through their complete routing journey with aggregate stats
"""

import os
from datetime import datetime, timedelta
from flask import Flask, jsonify, request
from flask_cors import CORS
import psycopg2
from psycopg2.extras import RealDictCursor

app = Flask(__name__)
CORS(app)

# Database connection from environment
DB_HOST = os.environ.get('DB_HOST', 'orthanc-db')
DB_PORT = os.environ.get('DB_PORT', '5432')
DB_NAME = os.environ.get('DB_NAME', 'orthanc')
DB_USER = os.environ.get('DB_USER', 'orthanc')
DB_PASS = os.environ.get('DB_PASS', 'ChangeThisPassword')


def get_db():
    """Get database connection"""
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASS
    )


def init_db():
    """Create workflow tracking tables"""
    conn = get_db()
    cur = conn.cursor()
    
    # Main workflow tracking table
    cur.execute("""
        CREATE TABLE IF NOT EXISTS study_workflows (
            study_id VARCHAR(64) PRIMARY KEY,
            study_instance_uid VARCHAR(128),
            patient_name TEXT,
            study_description TEXT,
            
            -- Stage 1: Send to MERCURE for AI processing
            mercure_sent_at TIMESTAMP,
            mercure_sent_status VARCHAR(20) DEFAULT 'pending',
            mercure_job_id VARCHAR(64),
            
            -- Stage 2: Receive results back from MERCURE
            mercure_returned_at TIMESTAMP,
            mercure_return_status VARCHAR(20) DEFAULT 'waiting',
            
            -- Stage 3: Route QA Visualization to LPCH routers
            lpch_sent_at TIMESTAMP,
            lpch_status VARCHAR(20) DEFAULT 'pending',
            lpcht_sent_at TIMESTAMP,
            lpcht_status VARCHAR(20) DEFAULT 'pending',
            
            -- Stage 4: Route Structured Reports to MODLINK
            modlink_sent_at TIMESTAMP,
            modlink_status VARCHAR(20) DEFAULT 'pending',
            
            -- Overall workflow status
            workflow_status VARCHAR(20) DEFAULT 'started',
            last_error TEXT,
            error_stage VARCHAR(32),
            
            created_at TIMESTAMP DEFAULT NOW(),
            updated_at TIMESTAMP DEFAULT NOW()
        );
        
        CREATE INDEX IF NOT EXISTS idx_workflows_status ON study_workflows(workflow_status);
        CREATE INDEX IF NOT EXISTS idx_workflows_created ON study_workflows(created_at);
    """)
    
    # Event log for detailed tracking
    cur.execute("""
        CREATE TABLE IF NOT EXISTS workflow_events (
            id SERIAL PRIMARY KEY,
            study_id VARCHAR(64) NOT NULL,
            stage VARCHAR(32) NOT NULL,
            status VARCHAR(20) NOT NULL,
            destination VARCHAR(64),
            job_id VARCHAR(64),
            error_message TEXT,
            timestamp TIMESTAMP DEFAULT NOW()
        );
        
        CREATE INDEX IF NOT EXISTS idx_events_study ON workflow_events(study_id);
        CREATE INDEX IF NOT EXISTS idx_events_time ON workflow_events(timestamp);
    """)
    
    conn.commit()
    cur.close()
    conn.close()


@app.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok'})


# ═══════════════════════════════════════════════════════════════════════════════
# WORKFLOW TRACKING ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/workflow/start', methods=['POST'])
def start_workflow():
    """Start tracking a new study workflow"""
    data = request.json or {}
    
    study_id = data.get('study_id')
    if not study_id:
        return jsonify({'error': 'study_id required'}), 400
    
    conn = get_db()
    cur = conn.cursor()
    
    # Insert or update workflow
    cur.execute("""
        INSERT INTO study_workflows (study_id, study_instance_uid, patient_name, study_description, workflow_status)
        VALUES (%s, %s, %s, %s, 'started')
        ON CONFLICT (study_id) DO UPDATE SET
            study_instance_uid = EXCLUDED.study_instance_uid,
            patient_name = EXCLUDED.patient_name,
            study_description = EXCLUDED.study_description,
            updated_at = NOW()
        RETURNING study_id
    """, (
        study_id,
        data.get('study_instance_uid'),
        data.get('patient_name'),
        data.get('study_description')
    ))
    
    # Log event
    cur.execute("""
        INSERT INTO workflow_events (study_id, stage, status)
        VALUES (%s, 'workflow', 'started')
    """, (study_id,))
    
    conn.commit()
    cur.close()
    conn.close()
    
    return jsonify({'ok': True, 'study_id': study_id})


@app.route('/workflow/update', methods=['POST'])
def update_workflow():
    """Update a workflow stage"""
    data = request.json or {}
    
    study_id = data.get('study_id')
    stage = data.get('stage')  # mercure_sent, mercure_returned, lpch, lpcht, modlink
    status = data.get('status')  # pending, sending, success, failed
    
    if not all([study_id, stage, status]):
        return jsonify({'error': 'study_id, stage, and status required'}), 400
    
    conn = get_db()
    cur = conn.cursor()
    
    # Map stage to column names
    stage_map = {
        'mercure_sent': ('mercure_sent_at', 'mercure_sent_status'),
        'mercure_returned': ('mercure_returned_at', 'mercure_return_status'),
        'lpch': ('lpch_sent_at', 'lpch_status'),
        'lpcht': ('lpcht_sent_at', 'lpcht_status'),
        'modlink': ('modlink_sent_at', 'modlink_status'),
    }
    
    if stage not in stage_map:
        return jsonify({'error': f'Invalid stage: {stage}'}), 400
    
    time_col, status_col = stage_map[stage]
    
    # Update the workflow
    error_msg = data.get('error')
    
    if status in ('success', 'failed'):
        # Update timestamp and status
        cur.execute(f"""
            UPDATE study_workflows 
            SET {time_col} = NOW(), 
                {status_col} = %s,
                last_error = CASE WHEN %s = 'failed' THEN %s ELSE last_error END,
                error_stage = CASE WHEN %s = 'failed' THEN %s ELSE error_stage END,
                updated_at = NOW()
            WHERE study_id = %s
        """, (status, status, error_msg, status, stage, study_id))
    else:
        # Just update status
        cur.execute(f"""
            UPDATE study_workflows 
            SET {status_col} = %s, updated_at = NOW()
            WHERE study_id = %s
        """, (status, study_id))
    
    # Log event
    cur.execute("""
        INSERT INTO workflow_events (study_id, stage, status, destination, error_message)
        VALUES (%s, %s, %s, %s, %s)
    """, (study_id, stage, status, data.get('destination'), error_msg))
    
    # Check if workflow is complete
    cur.execute("""
        SELECT mercure_sent_status, mercure_return_status, 
               lpch_status, lpcht_status, modlink_status
        FROM study_workflows WHERE study_id = %s
    """, (study_id,))
    row = cur.fetchone()
    
    if row:
        statuses = row
        # Workflow complete if all relevant stages succeeded
        # Note: Not all studies need all stages
        if statuses[0] == 'success' and statuses[1] == 'received':
            # Check if post-processing routes succeeded
            if statuses[2] == 'success' and statuses[3] == 'success':
                cur.execute("""
                    UPDATE study_workflows SET workflow_status = 'complete', updated_at = NOW()
                    WHERE study_id = %s
                """, (study_id,))
        
        # Check for stuck/failed
        if 'failed' in statuses:
            cur.execute("""
                UPDATE study_workflows SET workflow_status = 'failed', updated_at = NOW()
                WHERE study_id = %s
            """, (study_id,))
    
    conn.commit()
    cur.close()
    conn.close()
    
    return jsonify({'ok': True})


@app.route('/workflow/mercure-returned', methods=['POST'])
def mercure_returned():
    """Mark that MERCURE has returned results for a study"""
    data = request.json or {}
    study_id = data.get('study_id')
    
    if not study_id:
        return jsonify({'error': 'study_id required'}), 400
    
    conn = get_db()
    cur = conn.cursor()
    
    cur.execute("""
        UPDATE study_workflows 
        SET mercure_returned_at = NOW(), 
            mercure_return_status = 'received',
            workflow_status = 'processing',
            updated_at = NOW()
        WHERE study_id = %s
    """, (study_id,))
    
    cur.execute("""
        INSERT INTO workflow_events (study_id, stage, status)
        VALUES (%s, 'mercure_returned', 'received')
    """, (study_id,))
    
    conn.commit()
    cur.close()
    conn.close()
    
    return jsonify({'ok': True})


# ═══════════════════════════════════════════════════════════════════════════════
# QUERY ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/workflow/study/<study_id>', methods=['GET'])
def get_workflow(study_id):
    """Get workflow status for a specific study"""
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    cur.execute("""
        SELECT * FROM study_workflows WHERE study_id = %s
    """, (study_id,))
    workflow = cur.fetchone()
    
    cur.execute("""
        SELECT stage, status, destination, error_message, timestamp
        FROM workflow_events 
        WHERE study_id = %s 
        ORDER BY timestamp ASC
    """, (study_id,))
    events = cur.fetchall()
    
    cur.close()
    conn.close()
    
    if not workflow:
        return jsonify({'error': 'Workflow not found'}), 404
    
    # Convert timestamps
    for key, val in workflow.items():
        if isinstance(val, datetime):
            workflow[key] = val.isoformat()
    
    for event in events:
        if event.get('timestamp'):
            event['timestamp'] = event['timestamp'].isoformat()
    
    return jsonify({
        'workflow': workflow,
        'events': events
    })


@app.route('/workflow/recent', methods=['GET'])
def get_recent_workflows():
    """Get recent workflows"""
    limit = request.args.get('limit', 50, type=int)
    status = request.args.get('status')  # Optional filter
    
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    if status:
        cur.execute("""
            SELECT study_id, patient_name, study_description, workflow_status,
                   mercure_sent_status, mercure_return_status, 
                   lpch_status, lpcht_status, modlink_status,
                   last_error, error_stage, created_at, updated_at
            FROM study_workflows 
            WHERE workflow_status = %s
            ORDER BY updated_at DESC
            LIMIT %s
        """, (status, limit))
    else:
        cur.execute("""
            SELECT study_id, patient_name, study_description, workflow_status,
                   mercure_sent_status, mercure_return_status, 
                   lpch_status, lpcht_status, modlink_status,
                   last_error, error_stage, created_at, updated_at
            FROM study_workflows 
            ORDER BY updated_at DESC
            LIMIT %s
        """, (limit,))
    
    workflows = cur.fetchall()
    cur.close()
    conn.close()
    
    # Convert timestamps
    for w in workflows:
        for key in ['created_at', 'updated_at']:
            if w.get(key):
                w[key] = w[key].isoformat()
    
    return jsonify(workflows)


@app.route('/workflow/stuck', methods=['GET'])
def get_stuck_workflows():
    """Get workflows that appear stuck (no progress in 30+ minutes)"""
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    cur.execute("""
        SELECT study_id, patient_name, study_description, workflow_status,
               mercure_sent_status, mercure_return_status, 
               lpch_status, lpcht_status, modlink_status,
               last_error, error_stage, created_at, updated_at,
               EXTRACT(EPOCH FROM (NOW() - updated_at))/60 as minutes_since_update
        FROM study_workflows 
        WHERE workflow_status NOT IN ('complete', 'failed')
          AND updated_at < NOW() - INTERVAL '30 minutes'
        ORDER BY updated_at ASC
    """)
    
    stuck = cur.fetchall()
    cur.close()
    conn.close()
    
    for w in stuck:
        for key in ['created_at', 'updated_at']:
            if w.get(key):
                w[key] = w[key].isoformat()
    
    return jsonify(stuck)


# ═══════════════════════════════════════════════════════════════════════════════
# AGGREGATE STATISTICS
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/workflow/stats', methods=['GET'])
def get_aggregate_stats():
    """Get aggregate workflow statistics"""
    # Time range filter
    hours = request.args.get('hours', 24, type=int)
    
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    # Overall workflow stats
    cur.execute("""
        SELECT 
            COUNT(*) as total,
            COUNT(*) FILTER (WHERE workflow_status = 'complete') as complete,
            COUNT(*) FILTER (WHERE workflow_status = 'failed') as failed,
            COUNT(*) FILTER (WHERE workflow_status IN ('started', 'processing')) as in_progress,
            COUNT(*) FILTER (WHERE workflow_status NOT IN ('complete', 'failed') 
                            AND updated_at < NOW() - INTERVAL '30 minutes') as stuck
        FROM study_workflows
        WHERE created_at > NOW() - INTERVAL '%s hours'
    """, (hours,))
    overall = cur.fetchone()
    
    # Per-stage success rates
    cur.execute("""
        SELECT 
            -- MERCURE send
            COUNT(*) FILTER (WHERE mercure_sent_status = 'success') as mercure_sent_success,
            COUNT(*) FILTER (WHERE mercure_sent_status = 'failed') as mercure_sent_failed,
            
            -- MERCURE return
            COUNT(*) FILTER (WHERE mercure_return_status = 'received') as mercure_returned,
            COUNT(*) FILTER (WHERE mercure_sent_status = 'success' 
                            AND mercure_return_status = 'waiting'
                            AND updated_at < NOW() - INTERVAL '30 minutes') as mercure_no_response,
            
            -- LPCH routing
            COUNT(*) FILTER (WHERE lpch_status = 'success') as lpch_success,
            COUNT(*) FILTER (WHERE lpch_status = 'failed') as lpch_failed,
            COUNT(*) FILTER (WHERE lpcht_status = 'success') as lpcht_success,
            COUNT(*) FILTER (WHERE lpcht_status = 'failed') as lpcht_failed,
            
            -- MODLINK routing
            COUNT(*) FILTER (WHERE modlink_status = 'success') as modlink_success,
            COUNT(*) FILTER (WHERE modlink_status = 'failed') as modlink_failed
            
        FROM study_workflows
        WHERE created_at > NOW() - INTERVAL '%s hours'
    """, (hours,))
    stages = cur.fetchone()
    
    # Failure breakdown by stage
    cur.execute("""
        SELECT error_stage, COUNT(*) as count
        FROM study_workflows
        WHERE workflow_status = 'failed'
          AND created_at > NOW() - INTERVAL '%s hours'
        GROUP BY error_stage
        ORDER BY count DESC
    """, (hours,))
    failures_by_stage = cur.fetchall()
    
    # Average processing times
    cur.execute("""
        SELECT 
            AVG(EXTRACT(EPOCH FROM (mercure_returned_at - mercure_sent_at))/60) 
                FILTER (WHERE mercure_returned_at IS NOT NULL) as avg_mercure_time_minutes,
            AVG(EXTRACT(EPOCH FROM (updated_at - created_at))/60) 
                FILTER (WHERE workflow_status = 'complete') as avg_total_time_minutes
        FROM study_workflows
        WHERE created_at > NOW() - INTERVAL '%s hours'
    """, (hours,))
    timing = cur.fetchone()
    
    cur.close()
    conn.close()
    
    # Calculate success rates
    def rate(success, total):
        if total and total > 0:
            return round(success / total * 100, 1)
        return None
    
    mercure_total = (stages['mercure_sent_success'] or 0) + (stages['mercure_sent_failed'] or 0)
    lpch_total = (stages['lpch_success'] or 0) + (stages['lpch_failed'] or 0)
    modlink_total = (stages['modlink_success'] or 0) + (stages['modlink_failed'] or 0)
    
    return jsonify({
        'time_range_hours': hours,
        'overall': {
            'total': overall['total'] or 0,
            'complete': overall['complete'] or 0,
            'failed': overall['failed'] or 0,
            'in_progress': overall['in_progress'] or 0,
            'stuck': overall['stuck'] or 0,
            'success_rate': rate(overall['complete'], overall['total'])
        },
        'stages': {
            'mercure_send': {
                'success': stages['mercure_sent_success'] or 0,
                'failed': stages['mercure_sent_failed'] or 0,
                'success_rate': rate(stages['mercure_sent_success'], mercure_total)
            },
            'mercure_return': {
                'received': stages['mercure_returned'] or 0,
                'no_response': stages['mercure_no_response'] or 0
            },
            'lpch': {
                'success': stages['lpch_success'] or 0,
                'failed': stages['lpch_failed'] or 0,
                'success_rate': rate(stages['lpch_success'], lpch_total)
            },
            'lpcht': {
                'success': stages['lpcht_success'] or 0,
                'failed': stages['lpcht_failed'] or 0,
                'success_rate': rate(stages['lpcht_success'], lpch_total)
            },
            'modlink': {
                'success': stages['modlink_success'] or 0,
                'failed': stages['modlink_failed'] or 0,
                'success_rate': rate(stages['modlink_success'], modlink_total)
            }
        },
        'failures_by_stage': failures_by_stage,
        'timing': {
            'avg_mercure_response_minutes': round(timing['avg_mercure_time_minutes'], 1) if timing['avg_mercure_time_minutes'] else None,
            'avg_total_workflow_minutes': round(timing['avg_total_time_minutes'], 1) if timing['avg_total_time_minutes'] else None
        }
    })


@app.route('/workflow/stats/destinations', methods=['GET'])
def get_destination_stats():
    """Get per-destination statistics (for backward compatibility with old UI)"""
    hours = request.args.get('hours', 24, type=int)
    
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    # Build destination stats from workflow data
    cur.execute("""
        SELECT 
            'MERCURE' as destination,
            COUNT(*) FILTER (WHERE mercure_sent_status = 'success') as success,
            COUNT(*) FILTER (WHERE mercure_sent_status = 'failed') as failed,
            COUNT(*) FILTER (WHERE mercure_sent_status = 'pending') as pending,
            MAX(mercure_sent_at) as last_activity
        FROM study_workflows
        WHERE created_at > NOW() - INTERVAL '%s hours'
        
        UNION ALL
        
        SELECT 
            'LPCHROUTER' as destination,
            COUNT(*) FILTER (WHERE lpch_status = 'success') as success,
            COUNT(*) FILTER (WHERE lpch_status = 'failed') as failed,
            COUNT(*) FILTER (WHERE lpch_status = 'pending') as pending,
            MAX(lpch_sent_at) as last_activity
        FROM study_workflows
        WHERE created_at > NOW() - INTERVAL '%s hours'
        
        UNION ALL
        
        SELECT 
            'LPCHTROUTER' as destination,
            COUNT(*) FILTER (WHERE lpcht_status = 'success') as success,
            COUNT(*) FILTER (WHERE lpcht_status = 'failed') as failed,
            COUNT(*) FILTER (WHERE lpcht_status = 'pending') as pending,
            MAX(lpcht_sent_at) as last_activity
        FROM study_workflows
        WHERE created_at > NOW() - INTERVAL '%s hours'
        
        UNION ALL
        
        SELECT 
            'MODLINK' as destination,
            COUNT(*) FILTER (WHERE modlink_status = 'success') as success,
            COUNT(*) FILTER (WHERE modlink_status = 'failed') as failed,
            COUNT(*) FILTER (WHERE modlink_status = 'pending') as pending,
            MAX(modlink_sent_at) as last_activity
        FROM study_workflows
        WHERE created_at > NOW() - INTERVAL '%s hours'
    """, (hours, hours, hours, hours))
    
    results = cur.fetchall()
    cur.close()
    conn.close()
    
    # Calculate success rates and format
    stats = []
    for row in results:
        total = (row['success'] or 0) + (row['failed'] or 0)
        stats.append({
            'destination': row['destination'],
            'success': row['success'] or 0,
            'failed': row['failed'] or 0,
            'pending': row['pending'] or 0,
            'success_rate': round(row['success'] / total * 100, 1) if total > 0 else None,
            'last_activity': row['last_activity'].isoformat() if row['last_activity'] else None
        })
    
    return jsonify(stats)


# Keep old endpoint for backward compatibility
@app.route('/routing/stats', methods=['GET'])
def routing_stats_compat():
    """Backward compatible routing stats endpoint"""
    return get_destination_stats()


# ═══════════════════════════════════════════════════════════════════════════════
# INITIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

def init_on_startup():
    """Initialize database when app starts"""
    import time
    max_retries = 10
    for attempt in range(max_retries):
        try:
            print(f"Initializing workflow database (attempt {attempt + 1}/{max_retries})...")
            init_db()
            print("Database initialized successfully!")
            return
        except Exception as e:
            print(f"Database init failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(2)
    print("WARNING: Could not initialize database after retries")

# Run init when module loads
init_on_startup()

if __name__ == '__main__':
    print("Starting routing workflow API on port 5000...")
    app.run(host='0.0.0.0', port=5000)
