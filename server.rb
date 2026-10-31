#!/usr/bin/ruby
# Captación de Clientes - servidor local (Ruby estándar de macOS, sin instalar nada).
# Uso: ruby server.rb   →  http://localhost:4567
Encoding.default_external = 'UTF-8'
Encoding.default_internal = 'UTF-8'
$stdout.sync = true

require 'webrick'
require 'json'
require 'securerandom'
require 'digest'
require 'fileutils'
require 'openssl'
require 'date'
require 'uri'

require_relative 'lib/env'
Env.load!
require_relative 'lib/db'
require_relative 'lib/http_client'
require_relative 'lib/sectors'
require_relative 'lib/sources/nominatim'
require_relative 'lib/sources/overpass'
require_relative 'lib/sources/google_places'
require_relative 'lib/analyzer'
require_relative 'lib/scoring'
require_relative 'lib/search'
require_relative 'lib/companies'
require_relative 'lib/ai'
require_relative 'lib/export'

DB.setup!

PORT = Env.int('PORT', 4567)
# En internet (Render) se escucha en 0.0.0.0 y se activan las protecciones del modo público.
BIND = Env.get('BIND_ADDRESS', '127.0.0.1')
PUBLIC_MODE = BIND != '127.0.0.1' || Env.get('PUBLIC_MODE') == '1'
MIN_PASSWORD = PUBLIC_MODE ? 12 : 8
PUBLIC = File.join(Env::ROOT, 'public')
SESSION_DAYS = 14

class ApiError < StandardError
  attr_reader :status
  def initialize(msg, status = 400)
    super(msg)
    @status = status
  end
end

# ---------- Límites de uso (en memoria) ----------
module RateLimit
  @hits = Hash.new { |h, k| h[k] = [] }
  @lock = Mutex.new
  def self.check!(bucket, max, window_s)
    @lock.synchronize do
      now = Time.now.to_f
      list = @hits[bucket]
      list.reject! { |t| t < now - window_s }
      if list.size >= max
        mins = ((list.first + window_s - now) / 60.0).ceil
        raise ApiError.new("Has alcanzado el límite de uso. Vuelve a intentarlo en #{mins} min.", 429)
      end
      list << now
    end
  end
end

# ---------- Autenticación ----------
module Auth
  def self.hash(password, salt)
    OpenSSL::PKCS5.pbkdf2_hmac(password, salt, 200_000, 32, OpenSSL::Digest::SHA256.new).unpack1('H*')
  end

  def self.create_user(username, password)
    raise ApiError, 'El usuario debe tener al menos 3 caracteres' if username.to_s.strip.length < 3
    raise ApiError, "La contraseña debe tener al menos #{MIN_PASSWORD} caracteres" if password.to_s.length < MIN_PASSWORD
    salt = SecureRandom.hex(16)
    DB.run('INSERT INTO users(username, pass_hash, salt, created_at) VALUES (?, ?, ?, ?)', [username.strip, hash(password, salt), salt, DB.now])
  end

  def self.login(username, password)
    u = DB.one('SELECT * FROM users WHERE username = ?', [username.to_s.strip])
    ok = u && OpenSSL.fixed_length_secure_compare(hash(password.to_s, u['salt']), u['pass_hash']) rescue false
    raise ApiError.new('Usuario o contraseña incorrectos', 401) unless ok
    token = SecureRandom.hex(32)
    DB.run('INSERT INTO sessions(token, user_id, expires_at) VALUES (?, ?, ?)', [token, u['id'], (Time.now.utc + SESSION_DAYS * 86_400).strftime('%Y-%m-%dT%H:%M:%SZ')])
    token
  end

  def self.user_for(token)
    return nil if token.to_s.empty?
    DB.one('SELECT u.id, u.username FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token = ? AND s.expires_at > ?', [token, DB.now])
  end
end

# OpenSSL.fixed_length_secure_compare no existe en Ruby 2.6: comparación en tiempo constante propia.
unless OpenSSL.respond_to?(:fixed_length_secure_compare)
  module OpenSSL
    def self.fixed_length_secure_compare(a, b)
      return false unless a.bytesize == b.bytesize
      r = 0
      a.bytes.zip(b.bytes) { |x, y| r |= x ^ y }
      r.zero?
    end
  end
end

# ---------- Utilidades HTTP ----------
def json(res, data, status = 200)
  res.status = status
  res['Content-Type'] = 'application/json; charset=utf-8'
  res['Cache-Control'] = 'no-store'
  res.body = JSON.generate(data)
end

def body_json(req)
  return {} if req.body.to_s.empty?
  JSON.parse(req.body.force_encoding('UTF-8'))
rescue JSON::ParserError
  raise ApiError, 'Petición mal formada'
end

def query(req)
  q = {}
  URI.decode_www_form(req.query_string.to_s).each { |k, v| q[k] = v.force_encoding('UTF-8') }
  q
end

def session_token(req)
  c = req.cookies.find { |x| x.name == 'cc_session' }
  c && c.value
end

def set_cookie(res, token, max_age)
  res['Set-Cookie'] = "cc_session=#{token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=#{max_age}#{PUBLIC_MODE ? '; Secure' : ''}"
end

# Detrás del proxy de Render la IP real llega en X-Forwarded-For.
def client_ip(req)
  fwd = req['X-Forwarded-For'].to_s.split(',').first.to_s.strip
  PUBLIC_MODE && !fwd.empty? ? fwd : req.peeraddr[3]
end

SECURITY_HEADERS = {
  'X-Frame-Options' => 'DENY',
  'X-Content-Type-Options' => 'nosniff',
  'Referrer-Policy' => 'no-referrer',
  'Permissions-Policy' => 'camera=(), microphone=(), geolocation=()',
  'Content-Security-Policy' => "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
}.freeze

MIME = { '.html' => 'text/html; charset=utf-8', '.js' => 'application/javascript; charset=utf-8', '.css' => 'text/css; charset=utf-8',
         '.svg' => 'image/svg+xml', '.png' => 'image/png', '.ico' => 'image/x-icon' }.freeze

def serve_static(req, res)
  path = req.path == '/' ? '/index.html' : req.path
  file = File.expand_path(File.join(PUBLIC, path))
  file = File.join(PUBLIC, 'index.html') unless file.start_with?(PUBLIC) && File.file?(file)
  res['Content-Type'] = MIME[File.extname(file)] || 'application/octet-stream'
  res['Cache-Control'] = 'no-cache'
  res.body = File.binread(file)
end

def company_payload(c)
  c.merge('events' => Companies.events(c['id']),
          'drafts' => DB.all('SELECT * FROM drafts WHERE company_id = ? ORDER BY created_at DESC, id', [c['id']]),
          'searches' => DB.all('SELECT s.id, s.raw_text, s.created_at FROM search_results sr JOIN searches s ON s.id = sr.search_id WHERE sr.company_id = ? ORDER BY s.created_at DESC', [c['id']]))
end

def search_params(b)
  p = {}
  %w[raw_text offer customer_type sector location postcode city ideal website instagram email].each { |k| p[k] = b[k].to_s.strip[0, 500] }
  p['limit'] = [[b['limit'].to_i, 1].max, Search::MAX_LEADS].min
  p['limit'] = 20 if b['limit'].to_i.zero?
  p['min_score'] = b['min_score'].to_i
  p['exclude_saved'] = b['exclude_saved'] ? true : false
  # Barra rápida: «clínicas dentales en Barcelona»
  if p['sector'].empty? && !p['raw_text'].empty?
    parts = p['raw_text'].split(/\s+(?:en|de|a|por)\s+(?=[^\s]+)/i, 2)
    if parts.size == 2 && p['location'].empty?
      p['sector'], p['location'] = parts.map(&:strip)
    else
      p['sector'] = p['raw_text']
    end
  end
  raise ApiError, 'Indica qué tipo de negocio buscas (sector)' if p['sector'].empty?
  raise ApiError, 'Indica la ubicación (ciudad, provincia, comunidad o país) o un código postal' if p['location'].empty? && p['postcode'].empty?
  p
end

def reanalyze(c)
  sym = {}
  c.each { |k, v| sym[k.to_sym] = v }
  sym[:field_sources] = c['field_sources'].is_a?(Hash) ? c['field_sources'] : {}
  sym[:found_in] = sym[:field_sources].values.map { |s| s['source'] }.select { |s| %w[OpenStreetMap Google\ Places].include?(s) }.uniq
  sym[:sector_tags] = c['sector_tags'].is_a?(Hash) ? c['sector_tags'] : {}
  enriched, analysis = Search.enrich(sym)
  ops = Scoring.opportunities(enriched, analysis)
  ctx = c['score_context'].is_a?(Hash) ? c['score_context'] : {}
  s = Scoring.score(enriched, analysis, ops, ctx)
  Companies.upsert(enriched, analysis, ops, s, ctx)
end

# ---------- Rutas API ----------
def route(req, res)
  path = req.path
  verb = req.request_method
  return json(res, ok: true) if path == '/healthz' # comprobación de salud de Render
  return serve_static(req, res) unless path.start_with?('/api/')
  if verb != 'GET' && req['X-Requested-With'] != 'fetch'
    raise ApiError.new('Petición no permitida', 403) # protección CSRF básica
  end

  # Rutas públicas
  case [verb, path]
  when ['GET', '/api/me']
    user = Auth.user_for(session_token(req))
    return json(res, user: user, setup_needed: DB.one('SELECT COUNT(*) n FROM users')['n'].zero?,
                     setup_code_required: PUBLIC_MODE, min_password: MIN_PASSWORD,
                     config: { google: GooglePlaces.enabled?, ai: AI.enabled?, model: AI.model })
  when ['POST', '/api/setup']
    raise ApiError.new('La cuenta ya está creada', 403) unless DB.one('SELECT COUNT(*) n FROM users')['n'].zero?
    b = body_json(req)
    # En internet, solo quien conoce SETUP_CODE (variable de entorno de Render) puede crear la cuenta.
    if PUBLIC_MODE
      RateLimit.check!("setup:#{client_ip(req)}", 5, 900)
      code = Env.get('SETUP_CODE')
      raise ApiError.new('Falta configurar SETUP_CODE en el servidor', 503) unless code
      raise ApiError.new('Código de instalación incorrecto', 403) unless OpenSSL.fixed_length_secure_compare(Digest::SHA256.hexdigest(b['setup_code'].to_s), Digest::SHA256.hexdigest(code))
    end
    Auth.create_user(b['username'], b['password'])
    token = Auth.login(b['username'], b['password'])
    set_cookie(res, token, SESSION_DAYS * 86_400)
    return json(res, ok: true)
  when ['POST', '/api/login']
    RateLimit.check!("login:#{client_ip(req)}", 8, 300)
    RateLimit.check!('login:global', 60, 3600)
    b = body_json(req)
    token = Auth.login(b['username'], b['password'])
    set_cookie(res, token, SESSION_DAYS * 86_400)
    return json(res, ok: true)
  when ['POST', '/api/logout']
    DB.run('DELETE FROM sessions WHERE token = ?', [session_token(req).to_s])
    set_cookie(res, '', 0)
    return json(res, ok: true)
  end

  user = Auth.user_for(session_token(req))
  raise ApiError.new('Inicia sesión para continuar', 401) unless user
  q = query(req)

  case [verb, path]
  when ['GET', '/api/meta']
    json(res, statuses: Companies::STATUSES, sectors: Sectors.labels, tiers: Scoring::TIERS.map(&:last))
  when ['POST', '/api/search']
    s = DB.settings
    RateLimit.check!('search', s['max_searches_per_hour'].to_i.clamp(1, 1000), 3600)
    running = DB.one("SELECT COUNT(*) n FROM searches WHERE status = 'en_curso'")['n']
    raise ApiError.new('Ya hay una búsqueda en curso. Espera a que termine.', 429) if running > 0
    p = search_params(body_json(req))
    id = DB.run("INSERT INTO searches(user_id, raw_text, params, status, progress, message, created_at) VALUES (?, ?, ?, 'en_curso', 0, 'Iniciando…', ?)",
                [user['id'], p['raw_text'].empty? ? "#{p['sector']} en #{p['location']}" : p['raw_text'], JSON.generate(p), DB.now])
    Thread.new { Search.run(id, p) }
    json(res, id: id)
  when ['GET', '/api/searches']
    json(res, DB.all('SELECT id, raw_text, params, location_label, status, message, total_found, sources_used, created_at, finished_at FROM searches ORDER BY id DESC LIMIT 200').map { |r| DB.decode(r) })
  when ['GET', '/api/stats']
    json(res, Companies.stats)
  when ['GET', '/api/leads']
    json(res, Companies.list(q, saved_only: true))
  when ['POST', '/api/companies/bulk-save']
    ids = Array(body_json(req)['ids']).map(&:to_i)
    ids.each { |i| Companies.set_saved(i, true) if Companies.get(i) && Companies.get(i)['saved'].to_i.zero? }
    json(res, ok: true, saved: ids.size)
  when ['GET', '/api/export']
    list = if q['scope'] == 'search' && q['search_id']
             Companies.list(q, search_id: q['search_id'].to_i)
           else
             Companies.list(q, saved_only: q['scope'] != 'all')
           end
    stamp = Time.now.strftime('%Y-%m-%d_%H%M')
    DB.audit('exportacion', "Exportación #{q['format']} de #{list.size} registros (#{q['scope'] || 'leads'})")
    if q['format'] == 'xlsx'
      res['Content-Type'] = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
      res['Content-Disposition'] = "attachment; filename=\"leads_#{stamp}.xlsx\""
      res.body = Export.xlsx(list)
    else
      res['Content-Type'] = 'text/csv; charset=utf-8'
      res['Content-Disposition'] = "attachment; filename=\"leads_#{stamp}.csv\""
      res.body = Export.csv(list)
    end
  when ['GET', '/api/settings']
    json(res, DB.settings)
  when ['PUT', '/api/settings']
    b = body_json(req)
    b.each do |k, v|
      next unless DB::DEFAULT_SETTINGS.key?(k)
      v = v.to_s.strip[0, 2000]
      raise ApiError, "El valor de #{k} debe ser un número" if k =~ /days|max_/ && v !~ /\A\d+\z/
      DB.run('INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)', [k, v])
    end
    DB.audit('ajustes', "Ajustes actualizados: #{b.keys.join(', ')}")
    json(res, DB.settings)
  when ['POST', '/api/retention/run']
    json(res, removed: Companies.apply_retention!)
  when ['GET', '/api/privacy']
    json(res, suppression: DB.all('SELECT label, reason, created_at, COUNT(*) claves FROM suppression GROUP BY label, created_at ORDER BY created_at DESC LIMIT 200'),
              audit: DB.all('SELECT * FROM audit_log ORDER BY id DESC LIMIT 200'))
  else
    route_dynamic(req, res, verb, path, q)
  end
end

def route_dynamic(req, res, verb, path, q)
  if (m = path.match(%r{\A/api/searches/(\d+)\z}))
    s = DB.decode(DB.one('SELECT * FROM searches WHERE id = ?', [m[1].to_i]))
    raise ApiError.new('Búsqueda no encontrada', 404) unless s
    if verb == 'DELETE'
      DB.run('DELETE FROM search_results WHERE search_id = ?', [s['id']])
      DB.run('DELETE FROM searches WHERE id = ?', [s['id']])
      return json(res, ok: true)
    end
    return json(res, s)
  end
  if (m = path.match(%r{\A/api/searches/(\d+)/results\z}))
    return json(res, Companies.list(q, search_id: m[1].to_i))
  end
  if (m = path.match(%r{\A/api/companies/(\d+)(/[a-z\-]+)?\z}))
    id = m[1].to_i
    c = Companies.get(id)
    raise ApiError.new('Empresa no encontrada (puede haber sido eliminada)', 404) unless c
    action = m[2]
    case [verb, action]
    when ['GET', nil]
      return json(res, company_payload(c))
    when ['PATCH', nil]
      begin
        Companies.update(id, body_json(req))
      rescue ArgumentError => e
        raise ApiError, e.message
      end
      return json(res, company_payload(Companies.get(id)))
    when ['POST', '/save']
      Companies.set_saved(id, body_json(req)['saved'] != false)
      return json(res, company_payload(Companies.get(id)))
    when ['POST', '/events']
      b = body_json(req)
      raise ApiError, 'Escribe el texto de la nota' if b['text'].to_s.strip.empty?
      kind = %w[nota contacto comentario].include?(b['kind']) ? b['kind'] : 'nota'
      Companies.add_event(id, kind, b['text'].to_s.strip[0, 4000], b['date'])
      DB.run('UPDATE companies SET last_contact_date = ? WHERE id = ?', [b['date'], id]) if kind == 'contacto' && !b['date'].to_s.empty?
      return json(res, company_payload(Companies.get(id)))
    when ['POST', '/reanalyze']
      RateLimit.check!('reanalyze', 60, 3600)
      reanalyze(c)
      Companies.add_event(id, 'sistema', 'Datos y web vueltos a comprobar')
      return json(res, company_payload(Companies.get(id)))
    when ['POST', '/ai']
      RateLimit.check!('ai', DB.setting('max_ai_per_hour').to_i.clamp(1, 1000), 3600)
      begin
        AI.generate(c)
      rescue ArgumentError, HttpClient::Error => e
        raise ApiError, e.message
      end
      return json(res, company_payload(Companies.get(id)))
    when ['POST', '/suppress']
      Companies.suppress(id, body_json(req)['reason'])
      return json(res, ok: true)
    end
  end
  if (m = path.match(%r{\A/api/drafts/(\d+)\z}))
    d = DB.one('SELECT * FROM drafts WHERE id = ?', [m[1].to_i])
    raise ApiError.new('Borrador no encontrado', 404) unless d
    if verb == 'DELETE'
      DB.run('DELETE FROM drafts WHERE id = ?', [d['id']])
      return json(res, ok: true)
    end
    if verb == 'PATCH'
      b = body_json(req)
      content = b.key?('content') ? b['content'].to_s[0, 20_000] : d['content']
      status = %w[borrador aprobado].include?(b['status']) ? b['status'] : d['status']
      DB.run('UPDATE drafts SET content = ?, status = ?, updated_at = ? WHERE id = ?', [content, status, DB.now, d['id']])
      Companies.add_event(d['company_id'], 'ia', "Borrador «#{d['title']}» aprobado") if status == 'aprobado' && d['status'] != 'aprobado'
      return json(res, DB.one('SELECT * FROM drafts WHERE id = ?', [d['id']]))
    end
  end
  raise ApiError.new('Ruta no encontrada', 404)
end

server = WEBrick::HTTPServer.new(
  BindAddress: BIND, Port: PORT,
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN), AccessLog: []
)
# Servlet propio: mount_proc de WEBrick no admite PATCH ni DELETE.
class AppServlet < WEBrick::HTTPServlet::AbstractServlet
  def service(req, res)
    SECURITY_HEADERS.each { |k, v| res[k] = v }
    res['Strict-Transport-Security'] = 'max-age=31536000' if PUBLIC_MODE
    route(req, res)
  rescue ApiError => e
    json(res, { error: e.message }, e.status)
  rescue StandardError => e
    warn "#{e.class}: #{e.message}\n#{e.backtrace.first(6).join("\n")}"
    json(res, { error: 'Error interno del servidor. Revisa la ventana de Terminal para más detalles.' }, 500)
  end
end
server.mount('/', AppServlet)

# Búsquedas que quedaron a medias si se cerró la app
DB.run("UPDATE searches SET status = 'error', message = 'Interrumpida: la aplicación se cerró durante la búsqueda' WHERE status = 'en_curso'")
Thread.new do
  loop do
    begin
      Companies.apply_retention!
      DB.run('DELETE FROM sessions WHERE expires_at < ?', [DB.now])
    rescue StandardError => e
      warn "Limpieza: #{e.message}"
    end
    sleep 3600
  end
end

trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }
puts "\n  Captación de Clientes funcionando en  http://#{PUBLIC_MODE ? BIND : 'localhost'}:#{PORT}#{PUBLIC_MODE ? '  (modo público)' : ''}"
puts "  Google Places: #{GooglePlaces.enabled? ? 'activado' : 'no configurado (se usa OpenStreetMap)'} · IA: #{AI.enabled? ? "activada (#{AI.model})" : 'no configurada'}"
puts "  Para cerrar la aplicación pulsa Ctrl+C en esta ventana.\n\n"
server.start
