"""
Orthanc Routing Workflow Tracker
Tracks studies through the AI processing pipeline with funnel visualization
Includes background job poller for accurate send status tracking
"""

import os
import threading
import time
import requests
from datetime import datetime, timedelta
from flask import Flask, jsonify, request
from flask_cors import CORS
import psycopg2
from psycopg2.extras import RealDictCursor

app = Flask(__name__)
CORS(app)

# Database connection from environment (Orthanc's DB)
DB_HOST = os.environ.get('DB_HOST', 'orthanc-db')
DB_PORT = os.environ.get('DB_PORT', '5432')
DB_NAME = os.environ.get('DB_NAME', 'orthanc')
DB_USER = os.environ.get('DB_USER', 'orthanc')
DB_PASS = os.environ.get('DB_PASS', 'ChangeThisPassword')

# Mercure Database connection (for AI processing status tracking)
MERCURE_DB_HOST = os.environ.get('MERCURE_DB_HOST', 'mercure_db_1')
MERCURE_DB_PORT = os.environ.get('MERCURE_DB_PORT', '5432')
MERCURE_DB_NAME = os.environ.get('MERCURE_DB_NAME', 'mercure')
MERCURE_DB_USER = os.environ.get('MERCURE_DB_USER', 'mercure')
MERCURE_DB_PASS = os.environ.get('MERCURE_DB_PASS', '')

# Orthanc connection for job polling
ORTHANC_URL = os.environ.get('ORTHANC_URL', 'http://orthanc:8042')
ORTHANC_USER = os.environ.get('ORTHANC_USER', 'orthanc_admin')
ORTHANC_PASS = os.environ.get('ORTHANC_PASS', 'helloaide123')

# Job poller settings
JOB_POLL_INTERVAL = int(os.environ.get('JOB_POLL_INTERVAL', '10'))  # seconds


def get_db():
    """Get connection to Orthanc's PostgreSQL database"""
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, database=DB_NAME,
        user=DB_USER, password=DB_PASS
    )


def get_mercure_db():
    """Get connection to Mercure's PostgreSQL database for AI processing status"""
    if not MERCURE_DB_PASS:
        return None  # Mercure integration not configured
    return psycopg2.connect(
        host=MERCURE_DB_HOST, port=MERCURE_DB_PORT, database=MERCURE_DB_NAME,
        user=MERCURE_DB_USER, password=MERCURE_DB_PASS
    )


def init_db():
    """Create workflow tracking tables"""
    conn = get_db()
    cur = conn.cursor()
    
    # Main workflow table
    cur.execute("""
        CREATE TABLE IF NOT EXISTS study_workflows (
            study_id VARCHAR(64) PRIMARY KEY,
            study_instance_uid VARCHAR(128),
            patient_name TEXT,
            study_description TEXT,
            
            -- Stage 1: Send to MERCURE
            mercure_sent_at TIMESTAMP,
            mercure_send_success BOOLEAN,
            mercure_send_error TEXT,
            
            -- Stage 2: AI Results received back
            ai_results_received_at TIMESTAMP,
            ai_results_received BOOLEAN DEFAULT FALSE,
            
            -- Stage 3a: Route QA Viz to LPCH Router
            lpch_sent_at TIMESTAMP,
            lpch_send_success BOOLEAN,
            lpch_send_error TEXT,
            
            -- Stage 3b: Route QA Viz to LPCH T Router
            lpcht_sent_at TIMESTAMP,
            lpcht_send_success BOOLEAN,
            lpcht_send_error TEXT,
            
            -- Stage 3c: Route SR to MODLINK
            modlink_sent_at TIMESTAMP,
            modlink_send_success BOOLEAN,
            modlink_send_error TEXT,
            
            created_at TIMESTAMP DEFAULT NOW(),
            updated_at TIMESTAMP DEFAULT NOW()
        );
        
        CREATE INDEX IF NOT EXISTS idx_workflows_created ON study_workflows(created_at);
    """)
    
    # Pending jobs table for tracking Orthanc job completion
    cur.execute("""
        CREATE TABLE IF NOT EXISTS pending_jobs (
            job_id VARCHAR(64) PRIMARY KEY,
            study_id VARCHAR(64) NOT NULL,
            destination VARCHAR(32) NOT NULL,
            queued_at TIMESTAMP DEFAULT NOW()
        );
        
        CREATE INDEX IF NOT EXISTS idx_pending_jobs_queued ON pending_jobs(queued_at);
    """)
    
    conn.commit()
    cur.close()
    conn.close()


# ═══════════════════════════════════════════════════════════════════════════════
# JOB POLLER - Background thread that checks Orthanc job status
# ═══════════════════════════════════════════════════════════════════════════════

def poll_pending_jobs():
    """Background thread that polls Orthanc for job completion status"""
    print(f"[JobPoller] Started - polling every {JOB_POLL_INTERVAL}s")
    
    while True:
        try:
            conn = get_db()
            cur = conn.cursor(cursor_factory=RealDictCursor)
            
            # Get all pending jobs
            cur.execute("SELECT job_id, study_id, destination FROM pending_jobs")
            pending = cur.fetchall()
            
            if pending:
                print(f"[JobPoller] Checking {len(pending)} pending jobs...")
            
            for job in pending:
                job_id = job['job_id']
                study_id = job['study_id']
                destination = job['destination']
                
                try:
                    # Query Orthanc for job status
                    resp = requests.get(
                        f"{ORTHANC_URL}/jobs/{job_id}",
                        auth=(ORTHANC_USER, ORTHANC_PASS),
                        timeout=5
                    )
                    
                    if resp.status_code == 404:
                        # Job doesn't exist anymore - might have been cleaned up
                        print(f"[JobPoller] Job {job_id} not found - removing from pending")
                        cur.execute("DELETE FROM pending_jobs WHERE job_id = %s", (job_id,))
                        continue
                    
                    job_info = resp.json()
                    state = job_info.get('State', 'Unknown')
                    
                    if state == 'Success':
                        # Job completed successfully
                        print(f"[JobPoller] ✓ Job {job_id} SUCCEEDED ({destination})")
                        update_workflow_status(cur, study_id, destination, True, None)
                        cur.execute("DELETE FROM pending_jobs WHERE job_id = %s", (job_id,))
                        
                    elif state == 'Failure':
                        # Job failed
                        error_msg = job_info.get('ErrorDescription') or job_info.get('ErrorCode') or 'Unknown error'
                        print(f"[JobPoller] ✗ Job {job_id} FAILED ({destination}): {error_msg}")
                        update_workflow_status(cur, study_id, destination, False, error_msg)
                        cur.execute("DELETE FROM pending_jobs WHERE job_id = %s", (job_id,))
                        
                    elif state in ('Running', 'Pending', 'Paused'):
                        # Still in progress
                        pass
                        
                    else:
                        print(f"[JobPoller] Unknown state for job {job_id}: {state}")
                        
                except requests.exceptions.RequestException as e:
                    print(f"[JobPoller] Error checking job {job_id}: {e}")
            
            conn.commit()
            cur.close()
            conn.close()
            
        except Exception as e:
            print(f"[JobPoller] Error: {e}")
        
        time.sleep(JOB_POLL_INTERVAL)


def update_workflow_status(cur, study_id, destination, success, error):
    """Update the workflow table with job completion status"""
    col_map = {
        'MERCURE': 'mercure',
        'LPCHROUTER': 'lpch',
        'LPCH': 'lpch',
        'LPCHTROUTER': 'lpcht',
        'LPCHT': 'lpcht',
        'MODLINK': 'modlink'
    }
    
    prefix = col_map.get(destination.upper())
    if not prefix:
        print(f"[JobPoller] Unknown destination: {destination}")
        return
    
    cur.execute(f"""
        UPDATE study_workflows 
        SET {prefix}_sent_at = COALESCE({prefix}_sent_at, NOW()),
            {prefix}_send_success = %s, 
            {prefix}_send_error = %s, 
            updated_at = NOW()
        WHERE study_id = %s
    """, (success, error, study_id))


@app.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok'})


# ═══════════════════════════════════════════════════════════════════════════════
# TRACKING ENDPOINTS (called by Lua)
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/track/start', methods=['POST'])
def track_start():
    """Start tracking a new study workflow"""
    import sys
    # Debug: log raw request info (flush immediately)
    print(f"[track/start] Content-Type: {request.content_type}", flush=True)
    print(f"[track/start] Raw data: {request.data[:500] if request.data else b'EMPTY'}", flush=True)
    
    data = request.json or {}
    print(f"[track/start] Parsed JSON: {data}", flush=True)
    
    study_id = data.get('study_id')
    if not study_id:
        print(f"[track/start] ERROR: No study_id in request", flush=True)
        return jsonify({'error': 'study_id required'}), 400
    
    print(f"[track/start] Inserting study_id={study_id}", flush=True)
    
    conn = get_db()
    cur = conn.cursor()
    
    cur.execute("""
        INSERT INTO study_workflows (study_id, study_instance_uid, patient_name, study_description)
        VALUES (%s, %s, %s, %s)
        ON CONFLICT (study_id) DO UPDATE SET
            patient_name = COALESCE(EXCLUDED.patient_name, study_workflows.patient_name),
            study_description = COALESCE(EXCLUDED.study_description, study_workflows.study_description),
            updated_at = NOW()
    """, (study_id, data.get('study_uid'), data.get('patient_name'), data.get('study_description')))
    
    conn.commit()
    cur.close()
    conn.close()
    return jsonify({'ok': True})


@app.route('/track/mercure-sent', methods=['POST'])
def track_mercure_sent():
    """Record MERCURE send attempt"""
    data = request.json or {}
    study_id = data.get('study_id')
    success = data.get('success', False)
    error = data.get('error')
    
    conn = get_db()
    cur = conn.cursor()
    
    cur.execute("""
        UPDATE study_workflows 
        SET mercure_sent_at = NOW(), mercure_send_success = %s, mercure_send_error = %s, updated_at = NOW()
        WHERE study_id = %s
    """, (success, error, study_id))
    
    conn.commit()
    cur.close()
    conn.close()
    return jsonify({'ok': True})


@app.route('/track/ai-results', methods=['POST'])
def track_ai_results():
    """Record AI results received back - also implies MERCURE was successful"""
    data = request.json or {}
    study_id = data.get('study_id')
    
    conn = get_db()
    cur = conn.cursor()
    
    # If we got AI results back, MERCURE must have succeeded
    # This handles cases where job polling missed the completion
    cur.execute("""
        UPDATE study_workflows 
        SET ai_results_received_at = NOW(), 
            ai_results_received = TRUE,
            mercure_sent_at = COALESCE(mercure_sent_at, NOW()),
            mercure_send_success = TRUE,
            updated_at = NOW()
        WHERE study_id = %s
    """, (study_id,))
    
    conn.commit()
    cur.close()
    conn.close()
    return jsonify({'ok': True})


@app.route('/track/destination', methods=['POST'])
def track_destination():
    """Record destination send attempt"""
    data = request.json or {}
    study_id = data.get('study_id')
    destination = data.get('destination', '').upper()
    success = data.get('success', False)
    error = data.get('error')
    
    conn = get_db()
    cur = conn.cursor()
    
    # Handle MERCURE separately
    if destination == 'MERCURE':
        cur.execute("""
            UPDATE study_workflows 
            SET mercure_sent_at = NOW(), mercure_send_success = %s, mercure_send_error = %s, updated_at = NOW()
            WHERE study_id = %s
        """, (success, error, study_id))
    else:
        # Map destination to column prefix
        col_map = {
            'LPCHROUTER': 'lpch',
            'LPCH': 'lpch',
            'LPCHTROUTER': 'lpcht',
            'LPCHT': 'lpcht',
            'MODLINK': 'modlink'
        }
        
        prefix = col_map.get(destination)
        if not prefix:
            conn.close()
            return jsonify({'error': f'Unknown destination: {destination}'}), 400
        
        cur.execute(f"""
            UPDATE study_workflows 
            SET {prefix}_sent_at = NOW(), {prefix}_send_success = %s, {prefix}_send_error = %s, updated_at = NOW()
            WHERE study_id = %s
        """, (success, error, study_id))
    
    conn.commit()
    cur.close()
    conn.close()
    return jsonify({'ok': True})


@app.route('/track/reset', methods=['POST'])
def track_reset():
    """Reset a study's tracking state for fresh reprocessing
    
    This clears all workflow data so the study can go through the pipeline again.
    Use this when you need to reprocess a study from scratch.
    """
    data = request.json or {}
    study_id = data.get('study_id')
    
    if not study_id:
        return jsonify({'error': 'study_id required'}), 400
    
    app.logger.info(f"[track/reset] Resetting study: {study_id}")
    
    conn = get_db()
    cur = conn.cursor()
    
    # Delete the existing workflow record - it will be recreated when reprocessed
    cur.execute("DELETE FROM study_workflows WHERE study_id = %s", (study_id,))
    
    # Also clean up any pending jobs for this study
    cur.execute("DELETE FROM pending_jobs WHERE study_id = %s", (study_id,))
    
    deleted_count = cur.rowcount
    
    conn.commit()
    cur.close()
    conn.close()
    
    app.logger.info(f"[track/reset] Study {study_id} reset complete")
    return jsonify({'ok': True, 'deleted': deleted_count})


@app.route('/track/job', methods=['POST'])
def track_job():
    """Register a pending job to be tracked for completion by the background poller"""
    data = request.json or {}
    job_id = data.get('job_id')
    study_id = data.get('study_id')
    destination = data.get('destination', '').upper()
    
    if not all([job_id, study_id, destination]):
        return jsonify({'error': 'job_id, study_id, and destination required'}), 400
    
    conn = get_db()
    cur = conn.cursor()
    
    # Insert pending job for poller to track
    cur.execute("""
        INSERT INTO pending_jobs (job_id, study_id, destination)
        VALUES (%s, %s, %s)
        ON CONFLICT (job_id) DO UPDATE SET
            study_id = EXCLUDED.study_id,
            destination = EXCLUDED.destination,
            queued_at = NOW()
    """, (job_id, study_id, destination))
    
    conn.commit()
    cur.close()
    conn.close()
    
    print(f"[Track] Registered pending job {job_id} for {destination} (study: {study_id})")
    return jsonify({'ok': True, 'message': f'Job {job_id} registered for tracking'})


# ═══════════════════════════════════════════════════════════════════════════════
# QUERY ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/workflows', methods=['GET'])
def get_workflows():
    """Get recent workflows with their pipeline status"""
    limit = request.args.get('limit', 50, type=int)
    hours = request.args.get('hours', 24, type=int)
    
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    cur.execute("""
        SELECT 
            study_id,
            patient_name,
            study_description,
            
            -- Stage 1: MERCURE
            mercure_sent_at,
            mercure_send_success,
            mercure_send_error,
            
            -- Stage 2: AI Results
            ai_results_received_at,
            ai_results_received,
            
            -- Stage 3: Destinations
            lpch_sent_at, lpch_send_success, lpch_send_error,
            lpcht_sent_at, lpcht_send_success, lpcht_send_error,
            modlink_sent_at, modlink_send_success, modlink_send_error,
            
            created_at,
            updated_at
        FROM study_workflows
        WHERE created_at > NOW() - INTERVAL '%s hours'
        ORDER BY created_at DESC
        LIMIT %s
    """, (hours, limit))
    
    workflows = cur.fetchall()
    cur.close()
    conn.close()
    
    # Convert to pipeline format
    result = []
    for w in workflows:
        # Determine current stage and status
        pipeline = {
            'study_id': w['study_id'],
            'patient_name': w['patient_name'],
            'study_description': w['study_description'],
            'created_at': w['created_at'].isoformat() if w['created_at'] else None,
            'stages': {
                'mercure': {
                    'status': 'success' if w['mercure_send_success'] else ('failed' if w['mercure_send_success'] is False else 'pending'),
                    'timestamp': w['mercure_sent_at'].isoformat() if w['mercure_sent_at'] else None,
                    'error': w['mercure_send_error']
                },
                'ai_results': {
                    'status': 'received' if w['ai_results_received'] else 'waiting',
                    'timestamp': w['ai_results_received_at'].isoformat() if w['ai_results_received_at'] else None
                },
                'lpch': {
                    'status': 'success' if w['lpch_send_success'] else ('failed' if w['lpch_send_success'] is False else 'pending'),
                    'timestamp': w['lpch_sent_at'].isoformat() if w['lpch_sent_at'] else None,
                    'error': w['lpch_send_error']
                },
                'lpcht': {
                    'status': 'success' if w['lpcht_send_success'] else ('failed' if w['lpcht_send_success'] is False else 'pending'),
                    'timestamp': w['lpcht_sent_at'].isoformat() if w['lpcht_sent_at'] else None,
                    'error': w['lpcht_send_error']
                },
                'modlink': {
                    'status': 'success' if w['modlink_send_success'] else ('failed' if w['modlink_send_success'] is False else 'pending'),
                    'timestamp': w['modlink_sent_at'].isoformat() if w['modlink_sent_at'] else None,
                    'error': w['modlink_send_error']
                }
            }
        }
        result.append(pipeline)
    
    return jsonify(result)


@app.route('/workflows/<study_id>', methods=['GET'])
def get_workflow(study_id):
    """Get single workflow details"""
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    cur.execute("SELECT * FROM study_workflows WHERE study_id = %s", (study_id,))
    w = cur.fetchone()
    cur.close()
    conn.close()
    
    if not w:
        return jsonify({'error': 'Not found'}), 404
    
    return jsonify({
        'study_id': w['study_id'],
        'patient_name': w['patient_name'],
        'study_description': w['study_description'],
        'stages': {
            'mercure': {'status': 'success' if w['mercure_send_success'] else ('failed' if w['mercure_send_success'] is False else 'pending'), 'error': w['mercure_send_error']},
            'ai_results': {'status': 'received' if w['ai_results_received'] else 'waiting'},
            'lpch': {'status': 'success' if w['lpch_send_success'] else ('failed' if w['lpch_send_success'] is False else 'pending'), 'error': w['lpch_send_error']},
            'lpcht': {'status': 'success' if w['lpcht_send_success'] else ('failed' if w['lpcht_send_success'] is False else 'pending'), 'error': w['lpcht_send_error']},
            'modlink': {'status': 'success' if w['modlink_send_success'] else ('failed' if w['modlink_send_success'] is False else 'pending'), 'error': w['modlink_send_error']}
        }
    })


# ═══════════════════════════════════════════════════════════════════════════════
# FUNNEL / AGGREGATE STATS
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/funnel', methods=['GET'])
def get_funnel():
    """Get funnel/Sankey data showing flow through pipeline stages"""
    hours = request.args.get('hours', 24, type=int)
    
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    cur.execute("""
        SELECT 
            -- Total studies that entered the pipeline
            COUNT(*) as total_studies,
            
            -- Stage 1: Sent to MERCURE
            COUNT(*) FILTER (WHERE mercure_sent_at IS NOT NULL) as mercure_attempted,
            COUNT(*) FILTER (WHERE mercure_send_success = TRUE) as mercure_sent_ok,
            COUNT(*) FILTER (WHERE mercure_send_success = FALSE) as mercure_sent_failed,
            
            -- Stage 2: AI Results received
            COUNT(*) FILTER (WHERE ai_results_received = TRUE) as ai_results_received,
            COUNT(*) FILTER (WHERE mercure_send_success = TRUE AND ai_results_received = FALSE) as ai_results_waiting,
            
            -- Stage 3a: LPCH Router
            COUNT(*) FILTER (WHERE lpch_sent_at IS NOT NULL) as lpch_attempted,
            COUNT(*) FILTER (WHERE lpch_send_success = TRUE) as lpch_sent_ok,
            COUNT(*) FILTER (WHERE lpch_send_success = FALSE) as lpch_sent_failed,
            
            -- Stage 3b: LPCH T Router
            COUNT(*) FILTER (WHERE lpcht_sent_at IS NOT NULL) as lpcht_attempted,
            COUNT(*) FILTER (WHERE lpcht_send_success = TRUE) as lpcht_sent_ok,
            COUNT(*) FILTER (WHERE lpcht_send_success = FALSE) as lpcht_sent_failed,
            
            -- Stage 3c: MODLINK
            COUNT(*) FILTER (WHERE modlink_sent_at IS NOT NULL) as modlink_attempted,
            COUNT(*) FILTER (WHERE modlink_send_success = TRUE) as modlink_sent_ok,
            COUNT(*) FILTER (WHERE modlink_send_success = FALSE) as modlink_sent_failed,
            
            -- Fully complete (AI results + all destinations)
            COUNT(*) FILTER (WHERE 
                ai_results_received = TRUE AND
                lpch_send_success = TRUE AND
                lpcht_send_success = TRUE AND
                modlink_send_success = TRUE
            ) as fully_complete
            
        FROM study_workflows
        WHERE created_at > NOW() - INTERVAL '%s hours'
    """, (hours,))
    
    stats = cur.fetchone()
    cur.close()
    conn.close()
    
    # Build funnel data structure
    total = stats['total_studies'] or 0
    ai_received = stats['ai_results_received'] or 0
    
    def pct(n, base=None):
        base = base if base is not None else total
        return round(n / base * 100, 1) if base > 0 else 0
    
    # Calculate aggregate routing stats (any destination attempted after AI results)
    destinations_attempted = ai_received  # All studies with AI results should be routed
    destinations_all_success = stats['fully_complete'] or 0
    destinations_any_failed = (
        (stats['lpch_sent_failed'] or 0) + 
        (stats['lpcht_sent_failed'] or 0) + 
        (stats['modlink_sent_failed'] or 0)
    )
    
    funnel = {
        'time_range_hours': hours,
        'total_studies': total,
        
        # Main pipeline stages (top-level)
        'pipeline': [
            {
                'name': 'Studies Received',
                'count': total,
                'percent': 100,
                'status': 'neutral'
            },
            {
                'name': 'Sent to MERCURE',
                'count': stats['mercure_sent_ok'] or 0,
                'percent': pct(stats['mercure_sent_ok'] or 0),
                'failed': stats['mercure_sent_failed'] or 0,
                'status': 'success' if (stats['mercure_sent_failed'] or 0) == 0 else 'warning'
            },
            {
                'name': 'AI Results Back',
                'count': ai_received,
                'percent': pct(ai_received),
                'waiting': stats['ai_results_waiting'] or 0,
                'status': 'success' if (stats['ai_results_waiting'] or 0) == 0 else 'waiting'
            },
            {
                'name': 'Routed to Destinations',
                'count': destinations_all_success,
                'percent': pct(destinations_all_success, ai_received),
                'base_count': ai_received,
                'failed': destinations_any_failed,
                'status': 'success' if destinations_any_failed == 0 and ai_received > 0 else ('warning' if destinations_any_failed > 0 else 'neutral'),
                # Children destinations
                'children': [
                    {
                        'name': 'LPCH',
                        'count': stats['lpch_sent_ok'] or 0,
                        'percent': pct(stats['lpch_sent_ok'] or 0, ai_received),
                        'failed': stats['lpch_sent_failed'] or 0
                    },
                    {
                        'name': 'LPCHT',
                        'count': stats['lpcht_sent_ok'] or 0,
                        'percent': pct(stats['lpcht_sent_ok'] or 0, ai_received),
                        'failed': stats['lpcht_sent_failed'] or 0
                    },
                    {
                        'name': 'MODLINK',
                        'count': stats['modlink_sent_ok'] or 0,
                        'percent': pct(stats['modlink_sent_ok'] or 0, ai_received),
                        'failed': stats['modlink_sent_failed'] or 0
                    }
                ]
            }
        ],
        
        # Summary metrics
        'summary': {
            'mercure_success_rate': pct(ai_received, stats['mercure_sent_ok'] or 1),
            'routing_success_rate': pct(destinations_all_success, ai_received),
            'overall_success_rate': pct(stats['fully_complete'] or 0),
            'drop_off': {
                'mercure_send': stats['mercure_sent_failed'] or 0,
                'ai_no_response': stats['ai_results_waiting'] or 0,
                'routing_failed': destinations_any_failed
            }
        }
    }
    
    return jsonify(funnel)


@app.route('/funnel/timeseries', methods=['GET'])
def get_funnel_timeseries():
    """Get time-bucketed funnel stats for trend visualization"""
    hours = request.args.get('hours', 24, type=int)
    interval = request.args.get('interval', 'hour')  # 'hour' or 'day'
    
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    # Choose time bucket based on interval
    if interval == 'day':
        time_bucket = "date_trunc('day', created_at)"
        format_str = 'YYYY-MM-DD'
    else:
        time_bucket = "date_trunc('hour', created_at)"
        format_str = 'YYYY-MM-DD HH24:00'
    
    cur.execute(f"""
        SELECT 
            to_char({time_bucket}, '{format_str}') as time_bucket,
            COUNT(*) as studies_received,
            COUNT(*) FILTER (WHERE mercure_send_success = TRUE) as mercure_sent,
            COUNT(*) FILTER (WHERE ai_results_received = TRUE) as ai_results,
            COUNT(*) FILTER (WHERE lpch_send_success = TRUE) as lpch_routed,
            COUNT(*) FILTER (WHERE lpcht_send_success = TRUE) as lpcht_routed,
            COUNT(*) FILTER (WHERE modlink_send_success = TRUE) as modlink_routed,
            COUNT(*) FILTER (WHERE 
                ai_results_received = TRUE AND
                lpch_send_success = TRUE AND
                lpcht_send_success = TRUE AND
                modlink_send_success = TRUE
            ) as fully_complete
        FROM study_workflows
        WHERE created_at > NOW() - INTERVAL '{hours} hours'
        GROUP BY {time_bucket}
        ORDER BY {time_bucket} ASC
    """)
    
    rows = cur.fetchall()
    cur.close()
    conn.close()
    
    return jsonify({
        'interval': interval,
        'hours': hours,
        'data': rows
    })


# Backward compatibility
@app.route('/routing/stats', methods=['GET'])
@app.route('/workflow/stats/destinations', methods=['GET'])
def routing_stats_compat():
    """Backward compatible per-destination stats"""
    hours = request.args.get('hours', 24, type=int)
    
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    cur.execute("""
        SELECT 
            COUNT(*) FILTER (WHERE mercure_send_success = TRUE) as mercure_success,
            COUNT(*) FILTER (WHERE mercure_send_success = FALSE) as mercure_failed,
            COUNT(*) FILTER (WHERE mercure_sent_at IS NULL) as mercure_pending,
            
            COUNT(*) FILTER (WHERE lpch_send_success = TRUE) as lpch_success,
            COUNT(*) FILTER (WHERE lpch_send_success = FALSE) as lpch_failed,
            COUNT(*) FILTER (WHERE ai_results_received = TRUE AND lpch_sent_at IS NULL) as lpch_pending,
            
            COUNT(*) FILTER (WHERE lpcht_send_success = TRUE) as lpcht_success,
            COUNT(*) FILTER (WHERE lpcht_send_success = FALSE) as lpcht_failed,
            COUNT(*) FILTER (WHERE ai_results_received = TRUE AND lpcht_sent_at IS NULL) as lpcht_pending,
            
            COUNT(*) FILTER (WHERE modlink_send_success = TRUE) as modlink_success,
            COUNT(*) FILTER (WHERE modlink_send_success = FALSE) as modlink_failed,
            COUNT(*) FILTER (WHERE ai_results_received = TRUE AND modlink_sent_at IS NULL) as modlink_pending
            
        FROM study_workflows
        WHERE created_at > NOW() - INTERVAL '%s hours'
    """, (hours,))
    
    s = cur.fetchone()
    cur.close()
    conn.close()
    
    def rate(success, failed):
        total = (success or 0) + (failed or 0)
        return round(success / total * 100, 1) if total > 0 else None
    
    return jsonify([
        {'destination': 'MERCURE', 'success': s['mercure_success'] or 0, 'failed': s['mercure_failed'] or 0, 'pending': s['mercure_pending'] or 0, 'success_rate': rate(s['mercure_success'], s['mercure_failed'])},
        {'destination': 'LPCHROUTER', 'success': s['lpch_success'] or 0, 'failed': s['lpch_failed'] or 0, 'pending': s['lpch_pending'] or 0, 'success_rate': rate(s['lpch_success'], s['lpch_failed'])},
        {'destination': 'LPCHTROUTER', 'success': s['lpcht_success'] or 0, 'failed': s['lpcht_failed'] or 0, 'pending': s['lpcht_pending'] or 0, 'success_rate': rate(s['lpcht_success'], s['lpcht_failed'])},
        {'destination': 'MODLINK', 'success': s['modlink_success'] or 0, 'failed': s['modlink_failed'] or 0, 'pending': s['modlink_pending'] or 0, 'success_rate': rate(s['modlink_success'], s['modlink_failed'])}
    ])


# ═══════════════════════════════════════════════════════════════════════════════
# MERCURE STATUS ENDPOINTS (AI Processing Tracking)
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/mercure/status', methods=['GET'])
def mercure_status():
    """Check if Mercure integration is available"""
    try:
        conn = get_mercure_db()
        if conn is None:
            return jsonify({
                'available': False,
                'message': 'Mercure DB not configured. Set MERCURE_DB_PASS environment variable.'
            })
        conn.close()
        return jsonify({'available': True, 'message': 'Mercure DB connected'})
    except Exception as e:
        return jsonify({
            'available': False,
            'message': f'Mercure DB connection failed: {str(e)}'
        })


@app.route('/mercure/study/<study_uid>', methods=['GET'])
def mercure_study_status(study_uid):
    """Get Mercure processing status for a specific study
    
    This queries Mercure's database to get:
    - When the study was received
    - Processing tasks and their status
    - Error messages if any
    - When results were dispatched
    """
    try:
        conn = get_mercure_db()
        if conn is None:
            return jsonify({'error': 'Mercure integration not configured'}), 503
        
        cur = conn.cursor(cursor_factory=RealDictCursor)
        
        # Get all series for this study
        cur.execute("""
            SELECT 
                series_uid,
                study_uid,
                time as received_at,
                tag_patientname,
                tag_patientid,
                tag_studydescription,
                tag_seriesdescription,
                tag_modality
            FROM dicom_series
            WHERE study_uid = %s
            ORDER BY time ASC
        """, (study_uid,))
        
        series = cur.fetchall()
        
        # Get tasks associated with this study
        cur.execute("""
            SELECT 
                t.id as task_id,
                t.parent_id,
                t.time as task_created,
                t.series_uid,
                t.study_uid,
                t.data
            FROM tasks t
            WHERE t.study_uid = %s OR t.series_uid IN (
                SELECT series_uid FROM dicom_series WHERE study_uid = %s
            )
            ORDER BY t.time ASC
        """, (study_uid, study_uid))
        
        tasks = cur.fetchall()
        
        # Get task events for these tasks
        task_ids = [t['task_id'] for t in tasks if t['task_id']]
        events = []
        if task_ids:
            cur.execute("""
                SELECT 
                    task_id,
                    time,
                    sender,
                    event,
                    file_count,
                    target,
                    info
                FROM task_events
                WHERE task_id = ANY(%s)
                ORDER BY time ASC
            """, (task_ids,))
            events = cur.fetchall()
        
        cur.close()
        conn.close()
        
        # Parse task data and determine status
        processing_status = 'unknown'
        processing_start = None
        processing_end = None
        error_message = None
        dispatch_target = None
        
        for task in tasks:
            data = task.get('data') or {}
            if isinstance(data, str):
                import json
                try:
                    data = json.loads(data)
                except:
                    data = {}
            
            # Look for status info in task data
            if 'status' in data:
                processing_status = data['status']
            if 'error' in data:
                error_message = data.get('error')
            if 'dispatch' in data:
                dispatch_target = data.get('dispatch', {}).get('target_name')
        
        # Determine status from events
        for event in events:
            event_type = event.get('event', '').lower()
            if 'received' in event_type:
                processing_start = event['time']
            elif 'complete' in event_type or 'dispatch' in event_type:
                processing_end = event['time']
                processing_status = 'completed'
            elif 'error' in event_type or 'fail' in event_type:
                processing_status = 'failed'
                error_message = event.get('info')
        
        # Calculate processing duration
        processing_duration = None
        if processing_start and processing_end:
            duration = processing_end - processing_start
            processing_duration = duration.total_seconds()
        
        return jsonify({
            'study_uid': study_uid,
            'series_count': len(series),
            'series': [{
                'series_uid': s['series_uid'],
                'received_at': s['received_at'].isoformat() if s['received_at'] else None,
                'description': s['tag_seriesdescription'],
                'modality': s['tag_modality']
            } for s in series],
            'tasks': [{
                'task_id': t['task_id'],
                'created_at': t['task_created'].isoformat() if t['task_created'] else None,
                'series_uid': t['series_uid']
            } for t in tasks],
            'processing': {
                'status': processing_status,
                'started_at': processing_start.isoformat() if processing_start else None,
                'completed_at': processing_end.isoformat() if processing_end else None,
                'duration_seconds': processing_duration,
                'error': error_message,
                'dispatch_target': dispatch_target
            },
            'events': [{
                'time': e['time'].isoformat() if e['time'] else None,
                'event': e['event'],
                'sender': e['sender'],
                'target': e['target'],
                'info': e['info']
            } for e in events]
        })
        
    except Exception as e:
        app.logger.error(f"Error querying Mercure: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/mercure/recent', methods=['GET'])
def mercure_recent():
    """Get recent studies processed by Mercure
    
    Returns studies received by Mercure in the last N hours with their status.
    """
    hours = request.args.get('hours', 24, type=int)
    limit = request.args.get('limit', 50, type=int)
    
    try:
        conn = get_mercure_db()
        if conn is None:
            return jsonify({'error': 'Mercure integration not configured'}), 503
        
        cur = conn.cursor(cursor_factory=RealDictCursor)
        
        # Get unique studies received recently
        cur.execute("""
            SELECT DISTINCT ON (study_uid)
                study_uid,
                MIN(time) as first_received,
                MAX(time) as last_received,
                COUNT(*) as series_count,
                MAX(tag_patientname) as patient_name,
                MAX(tag_studydescription) as study_description
            FROM dicom_series
            WHERE time > NOW() - INTERVAL '%s hours'
            GROUP BY study_uid
            ORDER BY study_uid, first_received DESC
            LIMIT %s
        """, (hours, limit))
        
        studies = cur.fetchall()
        
        # For each study, get task status
        result = []
        for study in studies:
            study_uid = study['study_uid']
            
            # Get task info
            cur.execute("""
                SELECT 
                    t.id,
                    t.time,
                    t.data
                FROM tasks t
                WHERE t.study_uid = %s
                ORDER BY t.time DESC
                LIMIT 1
            """, (study_uid,))
            
            task = cur.fetchone()
            
            # Parse status from task data
            status = 'received'
            if task and task.get('data'):
                data = task['data']
                if isinstance(data, str):
                    import json
                    try:
                        data = json.loads(data)
                    except:
                        data = {}
                status = data.get('status', 'processing')
            
            result.append({
                'study_uid': study_uid,
                'patient_name': study['patient_name'],
                'study_description': study['study_description'],
                'series_count': study['series_count'],
                'received_at': study['first_received'].isoformat() if study['first_received'] else None,
                'mercure_status': status,
                'has_task': task is not None
            })
        
        cur.close()
        conn.close()
        
        return jsonify({
            'hours': hours,
            'count': len(result),
            'studies': result
        })
        
    except Exception as e:
        app.logger.error(f"Error querying Mercure: {e}")
        return jsonify({'error': str(e)}), 500


@app.route('/mercure/enrich/<study_id>', methods=['POST'])
def mercure_enrich_workflow(study_id):
    """Enrich a workflow record with Mercure processing status
    
    Fetches the study's Mercure status and updates our workflow tracking.
    """
    try:
        # First get the study_instance_uid from our workflow
        conn = get_db()
        cur = conn.cursor(cursor_factory=RealDictCursor)
        
        cur.execute("""
            SELECT study_instance_uid FROM study_workflows WHERE study_id = %s
        """, (study_id,))
        
        row = cur.fetchone()
        if not row or not row['study_instance_uid']:
            cur.close()
            conn.close()
            return jsonify({'error': 'Study not found or no StudyInstanceUID'}), 404
        
        study_uid = row['study_instance_uid']
        cur.close()
        conn.close()
        
        # Query Mercure for status
        mercure_conn = get_mercure_db()
        if mercure_conn is None:
            return jsonify({'error': 'Mercure integration not configured'}), 503
        
        mercure_cur = mercure_conn.cursor(cursor_factory=RealDictCursor)
        
        # Check if study exists in Mercure
        mercure_cur.execute("""
            SELECT COUNT(*) as count, MIN(time) as received_at
            FROM dicom_series
            WHERE study_uid = %s
        """, (study_uid,))
        
        mercure_info = mercure_cur.fetchone()
        
        # Get task events
        mercure_cur.execute("""
            SELECT event, time, info
            FROM task_events te
            JOIN tasks t ON te.task_id = t.id
            WHERE t.study_uid = %s
            ORDER BY te.time DESC
            LIMIT 10
        """, (study_uid,))
        
        events = mercure_cur.fetchall()
        
        mercure_cur.close()
        mercure_conn.close()
        
        # Determine Mercure status
        mercure_status = {
            'in_mercure': mercure_info['count'] > 0 if mercure_info else False,
            'received_at': mercure_info['received_at'].isoformat() if mercure_info and mercure_info['received_at'] else None,
            'series_count': mercure_info['count'] if mercure_info else 0,
            'events': [{
                'event': e['event'],
                'time': e['time'].isoformat() if e['time'] else None,
                'info': e['info']
            } for e in events]
        }
        
        # Check for completion or error events
        for event in events:
            event_name = event.get('event', '').lower()
            if 'complete' in event_name or 'dispatch' in event_name:
                mercure_status['processing_complete'] = True
                mercure_status['completed_at'] = event['time'].isoformat() if event['time'] else None
                break
            elif 'error' in event_name or 'fail' in event_name:
                mercure_status['processing_failed'] = True
                mercure_status['error'] = event.get('info')
                break
        
        return jsonify({
            'study_id': study_id,
            'study_uid': study_uid,
            'mercure': mercure_status
        })
        
    except Exception as e:
        app.logger.error(f"Error enriching workflow with Mercure data: {e}")
        return jsonify({'error': str(e)}), 500


# ═══════════════════════════════════════════════════════════════════════════════
# INITIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

_initialized = False
_poller_started = False

def init_on_startup():
    global _initialized
    if _initialized:
        return True
    
    for attempt in range(10):
        try:
            print(f"Initializing database (attempt {attempt + 1}/10)...", flush=True)
            init_db()
            print("Database ready!", flush=True)
            _initialized = True
            return True
        except Exception as e:
            print(f"Init failed: {e}", flush=True)
            if attempt < 9:
                time.sleep(2)
    return False


def start_job_poller():
    """Start the background job poller thread"""
    global _poller_started
    if _poller_started:
        return
    
    poller_thread = threading.Thread(target=poll_pending_jobs, daemon=True)
    poller_thread.start()
    _poller_started = True
    print("[Init] Job poller thread started", flush=True)


# Initialize database tables on module import
init_on_startup()


@app.before_request
def ensure_poller_running():
    """Ensure job poller is running (lazy start after fork)"""
    global _poller_started
    if not _poller_started and _initialized:
        start_job_poller()


if __name__ == '__main__':
    start_job_poller()
    app.run(host='0.0.0.0', port=5000)
