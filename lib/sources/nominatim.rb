require 'uri'

# Geocodificación con Nominatim (OpenStreetMap). Política de uso: máx. 1 petición/segundo,
# User-Agent identificable y caché de resultados. https://operations.osmfoundation.org/policies/nominatim/
module Nominatim
  BASE = 'https://nominatim.openstreetmap.org/search'.freeze
  LOCK = Mutex.new
  @last = Time.at(0)

  def self.throttle
    LOCK.synchronize do
      wait = 1.1 - (Time.now - @last)
      sleep(wait) if wait > 0
      @last = Time.now
    end
  end

  # params: {q:} o {postalcode:, country:}
  def self.search(params)
    key = params.to_a.sort.map { |k, v| "#{k}=#{v}" }.join('&')
    cached = DB.one('SELECT json FROM geocache WHERE q = ?', [key])
    return JSON.parse(cached['json']) if cached
    throttle
    query = URI.encode_www_form(params.merge(format: 'jsonv2', addressdetails: 1, limit: 5, 'accept-language' => 'es'))
    data = HttpClient.get_json("#{BASE}?#{query}", timeout: 20)
    DB.run('INSERT OR REPLACE INTO geocache(q, json, created_at) VALUES (?, ?, ?)', [key, JSON.generate(data), DB.now])
    data
  end

  # Resuelve la ubicación escrita por el usuario a un área de búsqueda.
  def self.resolve_location(text, postcode: nil)
    results = []
    if postcode && !postcode.empty?
      results = search(postalcode: postcode, country: 'España')
      results = search(q: "#{postcode} #{text}") if results.empty? && text && !text.empty?
      r = results.first
      raise HttpClient::Error, "No se encontró el código postal #{postcode}" unless r
      return build(r, mode: :around, radius: 1500, postcode: postcode)
    end
    raise HttpClient::Error, 'Indica una ubicación (ciudad, provincia, comunidad o país)' if text.to_s.strip.empty?
    results = search(q: text)
    raise HttpClient::Error, "No se encontró la ubicación «#{text}»" if results.empty?
    # Preferimos límites administrativos (relaciones) para poder buscar dentro del área exacta.
    r = results.find { |x| x['osm_type'] == 'relation' && %w[boundary place].include?(x['category']) } || results.first
    if r['osm_type'] == 'relation'
      build(r, mode: :area)
    else
      build(r, mode: :around, radius: 3000)
    end
  end

  # Búsqueda de negocios en Nominatim dentro del rectángulo del área (respaldo rápido de Overpass).
  # Usa «frases especiales» de OSM (p. ej. "dentist") o el texto libre si el sector no está mapeado.
  def self.search_pois(area, sector, limit)
    return [] unless area[:bbox]
    phrases = if sector[:selectors]
                sector[:selectors].map { |s| s[/="([^"]+)"\]\z/, 1] || s[/="([^"]+)"\]/, 1] }.compact.uniq.first(2).map { |v| v.tr('_', ' ') }
              else
                [sector[:term].to_s]
              end
    s, n, w, e = area[:bbox]
    out = []
    phrases.each do |phrase|
      exclude = []
      3.times do
        params = { q: phrase, format: 'jsonv2', viewbox: "#{w},#{n},#{e},#{s}", bounded: 1, limit: 40, extratags: 1, addressdetails: 1, 'accept-language' => 'es', countrycodes: 'es' }
        params[:exclude_place_ids] = exclude.join(',') unless exclude.empty?
        throttle
        data = HttpClient.get_json("#{BASE}?#{URI.encode_www_form(params)}", timeout: 25)
        break if data.empty?
        exclude.concat(data.map { |x| x['place_id'] })
        data.each do |x|
          c = poi_to_company(x, area)
          out << c if c
        end
        break if data.size < 40 || out.size >= limit * 2
      end
    end
    out
  end

  def self.poi_to_company(x, area)
    t = x['extratags'] || {}
    a = x['address'] || {}
    return nil if x['name'].to_s.strip.empty?
    city = a['city'] || a['town'] || a['village'] || a['municipality']
    # Si el área buscada es un municipio, descarta los negocios de municipios vecinos que entran en el rectángulo.
    if area[:mode] == :area && %w[city town village municipality].include?(area[:addresstype]) && city && area[:city] &&
       Sectors.normalize(city) != Sectors.normalize(area[:city])
      return nil
    end
    src = "https://www.openstreetmap.org/#{x['osm_type']}/#{x['osm_id']}"
    tags = { x['category'] => x['type'] }
    c = {
      name: x['name'].strip, sector: Sectors.label_from_tags(tags), sector_tags: tags,
      address: [a['road'], a['house_number']].compact.join(' ').then { |v| v.empty? ? nil : v },
      postcode: a['postcode'], city: city, province: a['province'] || a['county'], region: a['state'], country: a['country'],
      lat: x['lat'].to_f, lon: x['lon'].to_f,
      website: t['website'] || t['contact:website'] || t['url'], phone: t['phone'] || t['contact:phone'] || t['contact:mobile'],
      email: t['email'] || t['contact:email'], instagram: t['contact:instagram'], facebook: t['contact:facebook'],
      opening_hours: t['opening_hours'], osm_ref: src, field_sources: {}
    }
    %i[name address postcode city province region website phone email instagram facebook opening_hours].each do |f|
      c[:field_sources][f.to_s] = { 'source' => 'OpenStreetMap', 'url' => src } if c[f]
    end
    c
  end

  def self.build(r, mode:, radius: nil, postcode: nil)
    a = r['address'] || {}
    bb = r['boundingbox'] && r['boundingbox'].map(&:to_f) # [sur, norte, oeste, este]
    if mode == :around && radius
      d = radius / 111_000.0
      bb = [r['lat'].to_f - d, r['lat'].to_f + d, r['lon'].to_f - d * 1.35, r['lon'].to_f + d * 1.35]
    end
    {
      bbox: bb,
      mode: mode,
      area_id: r['osm_type'] == 'relation' ? 3_600_000_000 + r['osm_id'].to_i : nil,
      lat: r['lat'].to_f, lon: r['lon'].to_f, radius: radius,
      label: r['display_name'],
      addresstype: r['addresstype'],
      city: a['city'] || a['town'] || a['village'] || a['municipality'],
      province: a['province'] || a['county'],
      region: a['state'],
      country: a['country'],
      postcode: postcode
    }
  end
end
