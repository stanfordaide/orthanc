"""
Orthanc Routing Workflow Tracker
Tracks studies through the AI processing pipeline with funnel visualization
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
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, database=DB_NAME,
        user=DB_USER, password=DB_PASS
    )


def init_db():
    """Create workflow tracking table"""
    conn = get_db()
    cur = conn.cursor()
    
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
    
    conn.commit()
    cur.close()
    conn.close()


@app.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok'})


# ═══════════════════════════════════════════════════════════════════════════════
# TRACKING ENDPOINTS (called by Lua)
# ═══════════════════════════════════════════════════════════════════════════════

@app.route('/track/start', methods=['POST'])
def track_start():
    """Start tracking a new study workflow"""
    data = request.json or {}
    study_id = data.get('study_id')
    if not study_id:
        return jsonify({'error': 'study_id required'}), 400
    
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
    """Record AI results received back"""
    data = request.json or {}
    study_id = data.get('study_id')
    
    conn = get_db()
    cur = conn.cursor()
    
    cur.execute("""
        UPDATE study_workflows 
        SET ai_results_received_at = NOW(), ai_results_received = TRUE, updated_at = NOW()
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
        return jsonify({'error': f'Unknown destination: {destination}'}), 400
    
    conn = get_db()
    cur = conn.cursor()
    
    cur.execute(f"""
        UPDATE study_workflows 
        SET {prefix}_sent_at = NOW(), {prefix}_send_success = %s, {prefix}_send_error = %s, updated_at = NOW()
        WHERE study_id = %s
    """, (success, error, study_id))
    
    conn.commit()
    cur.close()
    conn.close()
    return jsonify({'ok': True})


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
    
    def pct(n):
        return round(n / total * 100, 1) if total > 0 else 0
    
    funnel = {
        'time_range_hours': hours,
        'total_studies': total,
        
        'stages': [
            {
                'name': 'Studies Received',
                'count': total,
                'percent': 100
            },
            {
                'name': 'Sent to MERCURE',
                'count': stats['mercure_sent_ok'] or 0,
                'percent': pct(stats['mercure_sent_ok'] or 0),
                'failed': stats['mercure_sent_failed'] or 0,
                'failed_reason': 'Send failed'
            },
            {
                'name': 'AI Results Received',
                'count': stats['ai_results_received'] or 0,
                'percent': pct(stats['ai_results_received'] or 0),
                'waiting': stats['ai_results_waiting'] or 0,
                'waiting_reason': 'Waiting for MERCURE response'
            },
            {
                'name': 'Routed to LPCH',
                'count': stats['lpch_sent_ok'] or 0,
                'percent': pct(stats['lpch_sent_ok'] or 0),
                'failed': stats['lpch_sent_failed'] or 0
            },
            {
                'name': 'Routed to LPCHT',
                'count': stats['lpcht_sent_ok'] or 0,
                'percent': pct(stats['lpcht_sent_ok'] or 0),
                'failed': stats['lpcht_sent_failed'] or 0
            },
            {
                'name': 'Routed to MODLINK',
                'count': stats['modlink_sent_ok'] or 0,
                'percent': pct(stats['modlink_sent_ok'] or 0),
                'failed': stats['modlink_sent_failed'] or 0
            },
            {
                'name': 'Fully Complete',
                'count': stats['fully_complete'] or 0,
                'percent': pct(stats['fully_complete'] or 0)
            }
        ],
        
        # Summary metrics
        'summary': {
            'mercure_success_rate': round((stats['ai_results_received'] or 0) / (stats['mercure_sent_ok'] or 1) * 100, 1) if stats['mercure_sent_ok'] else None,
            'overall_success_rate': pct(stats['fully_complete'] or 0),
            'drop_off': {
                'mercure_send': stats['mercure_sent_failed'] or 0,
                'ai_no_response': stats['ai_results_waiting'] or 0,
                'lpch_failed': stats['lpch_sent_failed'] or 0,
                'lpcht_failed': stats['lpcht_sent_failed'] or 0,
                'modlink_failed': stats['modlink_sent_failed'] or 0
            }
        }
    }
    
    return jsonify(funnel)


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
# INITIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

def init_on_startup():
    import time
    for attempt in range(10):
        try:
            print(f"Initializing database (attempt {attempt + 1}/10)...")
            init_db()
            print("Database ready!")
            return
        except Exception as e:
            print(f"Init failed: {e}")
            if attempt < 9:
                time.sleep(2)

init_on_startup()

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
