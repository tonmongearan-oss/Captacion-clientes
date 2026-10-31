require 'net/http'
require 'openssl'
require 'uri'
require 'resolv'
require 'ipaddr'
require 'json'

# Cliente HTTP con tiempos límite, redirecciones, tamaño máximo y protección frente a IPs privadas.
module HttpClient
  USER_AGENT = 'CaptacionClientes/1.0 (herramienta local de prospeccion B2B; respeta robots.txt)'.freeze
  PRIVATE_RANGES = %w[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8 169.254.0.0/16 0.0.0.0/8
                      ::1/128 fc00::/7 fe80::/10].map { |r| IPAddr.new(r) }.freeze

  class Error < StandardError; end

  Response = Struct.new(:code, :body, :headers, :final_url, :cert_valid)

  # Resuelve con el DNS del sistema y un límite de 6 s (el resolvedor de Ruby puede tardar minutos).
  def self.public_host?(host)
    t = Thread.new { Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map(&:ip_address).uniq rescue [] }
    addrs = t.join(6) ? t.value : []
    return false if addrs.empty?
    addrs.none? { |a| ip = (IPAddr.new(a) rescue nil); ip.nil? || PRIVATE_RANGES.any? { |r| r.include?(ip) } }
  rescue StandardError
    false
  end

  # Petición genérica. Para webs de terceros se usa check_public: true.
  def self.request(method, url, headers: {}, body: nil, form: nil, timeout: 15, max_bytes: 3_000_000,
                   redirects: 4, check_public: false, allow_insecure: false)
    uri = URI.parse(url)
    raise Error, 'URL no válida' unless uri.is_a?(URI::HTTP) && uri.host
    raise Error, 'El dominio no existe o no resuelve (DNS)' if check_public && !public_host?(uri.host)

    cert_valid = true
    begin
      res, data = perform(method, uri, headers, body, form, timeout, max_bytes, OpenSSL::SSL::VERIFY_PEER)
    rescue OpenSSL::SSL::SSLError => e
      raise Error, "Error SSL: #{e.message}" unless allow_insecure
      cert_valid = false
      res, data = perform(method, uri, headers, body, form, timeout, max_bytes, OpenSSL::SSL::VERIFY_NONE)
    end

    if res.is_a?(Net::HTTPRedirection) && redirects > 0 && res['location']
      next_url = URI.join(uri.to_s, res['location']).to_s
      r = request(method == :post ? :get : method, next_url, headers: headers, timeout: timeout, max_bytes: max_bytes,
                  redirects: redirects - 1, check_public: check_public, allow_insecure: allow_insecure)
      r.cert_valid = r.cert_valid && cert_valid if uri.scheme == 'https' && URI.parse(r.final_url).scheme == 'https'
      return r
    end
    hdrs = {}
    res.each_header { |k, v| hdrs[k.downcase] = v }
    Response.new(res.code.to_i, data, hdrs, uri.to_s, uri.scheme == 'https' ? cert_valid : nil)
  rescue Error
    raise
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, 'Tiempo de espera agotado'
  rescue SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET, EOFError => e
    raise Error, "No se pudo conectar (#{e.class.name.split('::').last})"
  rescue StandardError => e
    raise Error, "#{e.class.name}: #{e.message}"[0, 200]
  end

  def self.perform(method, uri, headers, body, form, timeout, max_bytes, verify)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.verify_mode = verify if http.use_ssl?
    http.open_timeout = [timeout, 10].min
    http.read_timeout = timeout
    req = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
    req['User-Agent'] = USER_AGENT
    req['Accept-Language'] = 'es-ES,es;q=0.9,ca;q=0.8,en;q=0.5'
    headers.each { |k, v| req[k] = v }
    if form
      req.set_form_data(form)
    elsif body
      req.body = body
    end
    data = +''
    response = nil
    http.start do |h|
      h.request(req) do |res|
        response = res
        res.read_body do |chunk|
          data << chunk
          break if data.bytesize > max_bytes
        end
      end
    end
    data.force_encoding('UTF-8')
    data = data.encode('UTF-8', 'ISO-8859-1') unless data.valid_encoding?
    [response, data]
  end

  def self.get_json(url, headers: {}, timeout: 30)
    r = request(:get, url, headers: { 'Accept' => 'application/json' }.merge(headers), timeout: timeout)
    raise Error, "HTTP #{r.code}" unless r.code == 200
    JSON.parse(r.body)
  end
end
