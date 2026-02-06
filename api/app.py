"""
Orthanc Routing Stats API
Simple Flask service to track routing events in PostgreSQL
"""

import os
from datetime import datetime
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
    """Create routing_events table if not exists"""
    conn = get_db()
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS routing_events (
            id SERIAL PRIMARY KEY,
            study_id VARCHAR(64) NOT NULL,
            destination VARCHAR(64) NOT NULL,
            status VARCHAR(20) NOT NULL,
            timestamp TIMESTAMP DEFAULT NOW(),
            error_message TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_routing_events_dest ON routing_events(destination);
        CREATE INDEX IF NOT EXISTS idx_routing_events_status ON routing_events(status);
        CREATE INDEX IF NOT EXISTS idx_routing_events_time ON routing_events(timestamp);
    """)
    conn.commit()
    cur.close()
    conn.close()


@app.route('/health', methods=['GET'])
def health():
    """Health check"""
    return jsonify({'status': 'ok'})


@app.route('/routing/event', methods=['POST'])
def record_event():
    """Record a routing event (called by Lua script)"""
    data = request.json or {}
    
    study_id = data.get('study_id', 'unknown')
    destination = data.get('destination', 'unknown')
    status = data.get('status', 'unknown')  # 'sent', 'success', 'failed'
    error_message = data.get('error')
    
    conn = get_db()
    cur = conn.cursor()
    cur.execute("""
        INSERT INTO routing_events (study_id, destination, status, error_message)
        VALUES (%s, %s, %s, %s)
    """, (study_id, destination, status, error_message))
    conn.commit()
    cur.close()
    conn.close()
    
    return jsonify({'ok': True})


@app.route('/routing/stats', methods=['GET'])
def get_stats():
    """Get routing statistics by destination"""
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    
    # Get stats per destination
    cur.execute("""
        SELECT 
            destination,
            COUNT(*) FILTER (WHERE status = 'sent') as sent,
            COUNT(*) FILTER (WHERE status = 'success') as success,
            COUNT(*) FILTER (WHERE status = 'failed') as failed,
            MAX(timestamp) as last_activity
        FROM routing_events
        GROUP BY destination
        ORDER BY destination
    """)
    stats = cur.fetchall()
    
    cur.close()
    conn.close()
    
    # Calculate success rate
    result = []
    for row in stats:
        sent = row['sent'] or 0
        success = row['success'] or 0
        failed = row['failed'] or 0
        total_complete = success + failed
        
        result.append({
            'destination': row['destination'],
            'sent': sent,
            'success': success,
            'failed': failed,
            'pending': sent - total_complete,
            'success_rate': round(success / total_complete * 100, 1) if total_complete > 0 else None,
            'last_activity': row['last_activity'].isoformat() if row['last_activity'] else None
        })
    
    return jsonify(result)


@app.route('/routing/recent', methods=['GET'])
def get_recent():
    """Get recent routing events"""
    limit = request.args.get('limit', 50, type=int)
    
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute("""
        SELECT study_id, destination, status, timestamp, error_message
        FROM routing_events
        ORDER BY timestamp DESC
        LIMIT %s
    """, (limit,))
    events = cur.fetchall()
    cur.close()
    conn.close()
    
    return jsonify([{
        **e,
        'timestamp': e['timestamp'].isoformat() if e['timestamp'] else None
    } for e in events])


# Initialize database on module load (works with gunicorn)
def init_on_startup():
    """Initialize database when app starts"""
    import time
    max_retries = 10
    for attempt in range(max_retries):
        try:
            print(f"Initializing routing stats database (attempt {attempt + 1}/{max_retries})...")
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
    print("Starting routing stats API on port 5000...")
    app.run(host='0.0.0.0', port=5000)
