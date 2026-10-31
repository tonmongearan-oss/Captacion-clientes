require 'uri'

# Analiza la web pública del propio negocio para obtener evidencias objetivas:
# HTTPS, adaptación a móvil, año de copyright, redes enlazadas, emails y teléfonos publicados, reservas online...
module Analyzer
  SOCIAL = {
    'instagram' => %r{https?://(?:www\.)?instagram\.com/([A-Za-z0-9_.]{2,30})/?}i,
    'facebook' => %r{https?://(?:www\.|m\.|es-es\.)?facebook\.com/(?!sharer|share|dialog|plugins|tr\b)([A-Za-z0-9_.\-/]{2,80})}i,
    'linkedin' => %r{https?://(?:[a-z]{2,3}\.)?linkedin\.com/(company|in|school)/([A-Za-z0-9_\-%.]{2,100})}i,
    'tiktok' => %r{https?://(?:www\.)?tiktok\.com/@([A-Za-z0-9_.]{2,30})}i,
    'youtube' => %r{https?://(?:www\.)?youtube\.com/(?:@|channel/|c/|user/)([A-Za-z0-9_\-]{2,60})}i
  }.freeze
  IG_RESERVED = %w[p reel reels explore accounts stories tv direct].freeze
  EMAIL_RX = /[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9.\-]{1,190}\.[A-Za-z]{2,10}/
  BAD_EMAIL = /(^(dpd|dpo|rgpd|gdpr|lopd|privacidad|privacy|protecciondedatos|legal|abuse|noreply|no-reply)@|example\.|sentry|wixpress|domain\.com|email\.com|\.(png|jpe?g|gif|svg|webp)$|^u00|@2x|yourdomain|tudominio|ejemplo)/i
  BOOKING_RX = /(reserva(r)? (online|ahora|cita|mesa)|pide (tu )?cita|cita online|book (now|online)|doctoralia|booksy|treatwell|thefork|eltenedor|calendly|reservio|simplybook|covermanager|opentable|appointment)/i
  CONTACT_FORM_RX = /<form[^>]*>(?:(?!<\/form>).){0,6000}?(email|mensaje|message|nombre|name)/im
  BUILDERS = { 'Wix' => /wix\.com|wixstatic/i, 'WordPress' => /wp-content|wordpress/i, 'Shopify' => /cdn\.shopify|myshopify/i,
               'Squarespace' => /squarespace/i, 'Jimdo' => /jimdo/i, 'Webnode' => /webnode/i, 'Joomla' => /joomla/i,
               'GoDaddy Website Builder' => /godaddy|wsimg\.com/i, 'Prestashop' => /prestashop/i }.freeze

  def self.normalize_url(url)
    u = url.to_s.strip
    return nil if u.empty?
    u = "https://#{u}" unless u =~ %r{\Ahttps?://}i
    URI.parse(u).host ? u : nil
  rescue URI::InvalidURIError
    nil
  end

  def self.domain(url)
    h = URI.parse(normalize_url(url).to_s).host.to_s.downcase
    h.sub(/\Awww\./, '')
  rescue StandardError
    nil
  end

  # Comprueba robots.txt de forma sencilla (User-agent: * y Disallow de la ruta).
  def self.robots_allows?(base, path)
    r = HttpClient.request(:get, URI.join(base, '/robots.txt').to_s, timeout: 6, max_bytes: 200_000, check_public: true, allow_insecure: true)
    return true unless r.code == 200
    applies = false
    r.body.each_line do |line|
      l = line.sub(/#.*/, '').strip
      next if l.empty?
      k, v = l.split(':', 2).map { |x| x.to_s.strip }
      case k.downcase
      when 'user-agent' then applies = (v == '*' || v.downcase.include?('captacionclientes'))
      when 'disallow' then return false if applies && !v.empty? && path.start_with?(v)
      end
    end
    true
  rescue HttpClient::Error
    true
  end

  def self.fetch(url)
    HttpClient.request(:get, url, timeout: 12, max_bytes: 2_500_000, check_public: true, allow_insecure: true,
                                  headers: { 'Accept' => 'text/html,application/xhtml+xml' })
  end

  def self.analyze(website)
    url = normalize_url(website)
    return { 'reachable' => false, 'error' => 'URL no válida' } unless url
    out = { 'checked_url' => url, 'checked_at' => DB.now }
    start = Time.now
    unless robots_allows?(url, '/')
      return out.merge('reachable' => nil, 'error' => 'robots.txt no permite el análisis automático; no se ha analizado')
    end
    res = fetch(url)
    # Si la URL publicada es una subpágina que ya no existe, analiza la portada del dominio.
    root = URI.join(url, '/').to_s
    if res.code >= 400 && root.chomp('/') != url.sub(/[#?].*\z/, '').chomp('/')
      out['listed_url_error'] = "La URL publicada (#{url}) responde HTTP #{res.code}; se ha analizado la portada #{root}"
      res = fetch(root)
    end
    out['load_seconds'] = (Time.now - start).round(1)
    out['status'] = res.code
    out['final_url'] = res.final_url
    out['reachable'] = res.code.between?(200, 399)
    unless out['reachable']
      out['error'] = "La web respondió con HTTP #{res.code}"
      return out
    end
    html = res.body
    out['https'] = res.final_url.start_with?('https://')
    out['cert_valid'] = res.cert_valid
    out['page_kb'] = (html.bytesize / 1024.0).round
    out['title'] = html[/<title[^>]*>(.*?)<\/title>/im, 1].to_s.gsub(/\s+/, ' ').strip[0, 160]
    out['description'] = html[/<meta[^>]+name=["']description["'][^>]*content=["']([^"']*)/i, 1].to_s.strip[0, 300]
    out['viewport'] = !!(html =~ /<meta[^>]+name=["']viewport["']/i)
    out['generator'] = html[/<meta[^>]+name=["']generator["'][^>]*content=["']([^"']*)/i, 1]
    out['builder'] = BUILDERS.find { |_, rx| html =~ rx }&.first
    years = html.scan(/(?:©|&copy;|&#169;|copyright)\s*(?:[^<\d]{0,40})?((?:19|20)\d{2})(?:\s*[-–]\s*((?:19|20)\d{2}))?/i).flatten.compact.map(&:to_i)
    years.select! { |y| y.between?(1995, Time.now.year + 1) }
    out['copyright_year'] = years.max
    out['last_modified'] = res.headers['last-modified']
    out['has_booking'] = !!(html =~ BOOKING_RX)
    out['has_contact_form'] = !!(html =~ CONTACT_FORM_RX)
    out['has_whatsapp'] = !!(html =~ %r{wa\.me/|api\.whatsapp\.com|whatsapp://}i)
    out['whatsapp_number'] = html[%r{wa\.me/(\d{9,15})}i, 1] || html[%r{api\.whatsapp\.com/send\?phone=(\d{9,15})}i, 1]
    out['social'] = extract_social(html)
    out['emails'] = extract_emails(html, domain(res.final_url))
    out['phones'] = html.scan(/href=["']tel:([+\d\s().\-]{9,20})["']/i).flatten.map { |p| p.gsub(/[^\d+]/, '') }.uniq.first(3)
    out['source_url'] = res.final_url

    # Si no hay email en la portada, prueba la página de contacto enlazada (una sola petición extra).
    if out['emails'].empty?
      link = html.scan(/href=["']([^"'#]*(?:contact|contacto|contacte|contactar)[^"'#]*)["']/i).flatten.first
      if link
        begin
          curl = URI.join(res.final_url, link).to_s
          if domain(curl) == domain(res.final_url)
            cr = fetch(curl)
            if cr.code == 200
              out['emails'] = extract_emails(cr.body, domain(res.final_url))
              out['email_source_url'] = curl unless out['emails'].empty?
              extract_social(cr.body).each { |k, v| out['social'][k] ||= v }
              out['has_contact_form'] ||= !!(cr.body =~ CONTACT_FORM_RX)
            end
          end
        rescue HttpClient::Error, URI::Error
          nil
        end
      end
    end
    out
  rescue HttpClient::Error => e
    out ||= {}
    out.merge('reachable' => false, 'error' => e.message)
  end

  def self.extract_social(html)
    found = {}
    SOCIAL.each do |net, rx|
      html.scan(rx).each do |m|
        handle = Array(m).last.to_s
        next if net == 'instagram' && IG_RESERVED.include?(handle.downcase)
        next if handle.empty?
        found[net] ||= html[rx].sub(/["'<>\s].*/, '')
        break
      end
    end
    found
  end

  def self.extract_emails(html, site_domain)
    text = html.gsub(/%40|&#64;|\[at\]/i, '@')
    emails = text.scan(EMAIL_RX).map(&:downcase).uniq.reject { |e| e =~ BAD_EMAIL }
    # Prioriza emails del propio dominio y genéricos (info@, contacto@...).
    emails.sort_by { |e| [e.end_with?("@#{site_domain}") ? 0 : 1, e =~ /\A(info|contact|hola|hello|admin|recep|clinica|citas|reservas)/ ? 0 : 1] }.first(3)
  end
end
