require 'sqlite3'
require 'json'
require 'monitor'

# Base de datos SQLite persistente (data/captacion.db). Una sola conexión protegida por un monitor,
# suficiente para una aplicación local de un solo equipo.
module DB
  # DATA_DIR permite usar un disco persistente en la nube (en Render: /var/data).
  DATA_DIR = Env.get('DATA_DIR', File.join(Env::ROOT, 'data'))
  PATH = File.join(DATA_DIR, 'captacion.db')
  LOCK = Monitor.new

  SCHEMA = <<~SQL
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY, username TEXT UNIQUE NOT NULL, pass_hash TEXT NOT NULL,
      salt TEXT NOT NULL, created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS sessions (
      token TEXT PRIMARY KEY, user_id INTEGER NOT NULL, expires_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS searches (
      id INTEGER PRIMARY KEY, user_id INTEGER, raw_text TEXT, params TEXT NOT NULL,
      location_label TEXT, status TEXT NOT NULL, progress INTEGER DEFAULT 0, message TEXT,
      total_found INTEGER DEFAULT 0, sources_used TEXT, created_at TEXT NOT NULL, finished_at TEXT);
    CREATE TABLE IF NOT EXISTS companies (
      id INTEGER PRIMARY KEY, dedup_key TEXT UNIQUE NOT NULL,
      name TEXT NOT NULL, sector TEXT, sector_tags TEXT,
      address TEXT, postcode TEXT, city TEXT, province TEXT, region TEXT, country TEXT,
      lat REAL, lon REAL,
      website TEXT, instagram TEXT, facebook TEXT, linkedin TEXT, tiktok TEXT,
      phone TEXT, email TEXT, whatsapp TEXT,
      decision_maker TEXT, decision_maker_source TEXT, employees TEXT, opening_hours TEXT,
      google_place_id TEXT, osm_ref TEXT, maps_url TEXT, rating REAL, rating_count INTEGER, business_status TEXT,
      field_sources TEXT, analysis TEXT, opportunities TEXT,
      score INTEGER, score_breakdown TEXT, score_explanation TEXT, score_tier TEXT, score_context TEXT,
      confidence TEXT,
      status TEXT NOT NULL DEFAULT 'Nuevo lead', saved INTEGER NOT NULL DEFAULT 0, saved_at TEXT,
      next_action TEXT, next_action_date TEXT, last_contact_date TEXT,
      lawful_basis TEXT, source_note TEXT,
      last_checked_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS idx_companies_saved ON companies(saved);
    CREATE TABLE IF NOT EXISTS search_results (
      search_id INTEGER NOT NULL, company_id INTEGER NOT NULL, position INTEGER,
      PRIMARY KEY (search_id, company_id));
    CREATE TABLE IF NOT EXISTS crm_events (
      id INTEGER PRIMARY KEY, company_id INTEGER NOT NULL, kind TEXT NOT NULL, text TEXT,
      event_date TEXT, created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS idx_events_company ON crm_events(company_id);
    CREATE TABLE IF NOT EXISTS drafts (
      id INTEGER PRIMARY KEY, company_id INTEGER NOT NULL, kind TEXT NOT NULL, title TEXT,
      content TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'borrador', model TEXT,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS suppression (
      id INTEGER PRIMARY KEY, key TEXT UNIQUE NOT NULL, label TEXT, reason TEXT, created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS geocache (q TEXT PRIMARY KEY, json TEXT, created_at TEXT);
    CREATE TABLE IF NOT EXISTS audit_log (
      id INTEGER PRIMARY KEY, action TEXT NOT NULL, detail TEXT, created_at TEXT NOT NULL);
  SQL

  DEFAULT_SETTINGS = {
    'retention_days_unsaved' => '30',
    'retention_days_saved' => '730',
    'default_lawful_basis' => 'Interés legítimo (art. 6.1.f RGPD): prospección comercial B2B usando únicamente datos de contacto profesionales publicados por la propia empresa.',
    'sender_name' => '',
    'sender_company' => '',
    'sender_offer' => '',
    'max_searches_per_hour' => '15',
    'max_ai_per_hour' => '40'
  }.freeze

  def self.conn
    @conn ||= begin
      FileUtils.mkdir_p(DATA_DIR)
      c = SQLite3::Database.new(PATH)
      c.results_as_hash = true
      c.busy_timeout = 5000
      c.execute('PRAGMA journal_mode=WAL')
      c.execute('PRAGMA foreign_keys=ON')
      c
    end
  end

  def self.setup!
    LOCK.synchronize do
      conn.execute_batch(SCHEMA)
      DEFAULT_SETTINGS.each do |k, v|
        conn.execute('INSERT OR IGNORE INTO settings(key, value) VALUES (?, ?)', [k, v])
      end
    end
  end

  # Devuelve filas como hashes con claves string (sin las claves numéricas que añade sqlite3 1.3).
  def self.all(sql, params = [])
    LOCK.synchronize do
      conn.execute(sql, utf8(params)).map { |row| row.reject { |k, _| k.is_a?(Integer) } }
    end
  end

  # sqlite3 guarda las cadenas binarias (p. ej. cookies de WEBrick) como BLOB: se pasan siempre a UTF-8.
  def self.utf8(params)
    params.map { |v| v.is_a?(String) && v.encoding != Encoding::UTF_8 ? v.dup.force_encoding('UTF-8') : v }
  end

  def self.one(sql, params = [])
    all(sql, params).first
  end

  def self.run(sql, params = [])
    LOCK.synchronize do
      conn.execute(sql, utf8(params))
      conn.last_insert_row_id
    end
  end

  def self.transaction
    LOCK.synchronize { conn.transaction { yield } }
  end

  def self.now
    Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
  end

  def self.setting(key)
    row = one('SELECT value FROM settings WHERE key = ?', [key])
    row ? row['value'] : DEFAULT_SETTINGS[key]
  end

  def self.settings
    h = DEFAULT_SETTINGS.dup
    all('SELECT key, value FROM settings').each { |r| h[r['key']] = r['value'] }
    h
  end

  def self.audit(action, detail)
    run('INSERT INTO audit_log(action, detail, created_at) VALUES (?, ?, ?)', [action, detail.to_s, now])
  end

  JSON_FIELDS = %w[field_sources analysis opportunities score_breakdown score_context sector_tags params sources_used].freeze

  # Convierte los campos JSON almacenados como texto en estructuras Ruby.
  def self.decode(row)
    return nil unless row
    JSON_FIELDS.each do |f|
      next unless row.key?(f) && row[f].is_a?(String)
      row[f] = (JSON.parse(row[f]) rescue row[f])
    end
    row
  end
end
