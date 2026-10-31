# Búsqueda de negocios reales en OpenStreetMap mediante la API Overpass (gratuita, sin clave).
# Datos © colaboradores de OpenStreetMap, licencia ODbL.
module Overpass
  ENDPOINTS = [
    Env.get('OVERPASS_URL', 'https://overpass-api.de/api/interpreter'),
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
    'https://overpass.private.coffee/api/interpreter'
  ].uniq.freeze
  LOCK = Mutex.new # una consulta a la vez, como pide la política de uso

  def self.build_query(area, sector, limit)
    scope = if area[:mode] == :area
              '(area.a)'
            else
              "(around:#{area[:radius] || 3000},#{area[:lat]},#{area[:lon]})"
            end
    selectors = if sector[:selectors]
                  sector[:selectors].map { |s| "#{s}[\"name\"]" }
                else
                  # Sector no mapeado: busca la palabra en el nombre o descripción de comercios/oficinas.
                  term = sector[:term].to_s.gsub(/[^\p{L}\p{N} ]/, '').strip
                  term = Sectors.normalize(term).split.max_by(&:length).to_s if term.length > 30
                  rx = term.chars.map { |c| accent_class(c) }.join
                  %w[shop office amenity craft healthcare tourism leisure].flat_map do |k|
                    ["[\"#{k}\"][\"name\"~\"#{rx}\",i]", "[\"#{k}\"][\"name\"][\"description\"~\"#{rx}\",i]"]
                  end
                end
    parts = selectors.map { |s| "nwr#{s}#{scope};" }.join("\n  ")
    header = area[:mode] == :area ? "area(id:#{area[:area_id]})->.a;\n" : ''
    "[out:json][timeout:90];\n#{header}(\n  #{parts}\n);\nout center tags #{limit};"
  end

  def self.accent_class(c)
    { 'a' => '[aáà]', 'e' => '[eéè]', 'i' => '[iíï]', 'o' => '[oóò]', 'u' => '[uúü]', 'n' => '[nñ]', 'c' => '[cç]' }[Sectors.normalize(c)] || c
  end

  def self.search(area, sector, limit)
    query = build_query(area, sector, [limit * 4, 400].min).sub('[timeout:90]', '[timeout:55]')
    data = nil
    errors = []
    LOCK.synchronize do
      # Servidor principal, reintento tras una pausa si está saturado (429/504), y después servidores alternativos.
      ENDPOINTS.each_with_index do |url, i|
        begin
          r = HttpClient.request(:post, url, form: { 'data' => query }, headers: { 'Accept' => 'application/json' }, timeout: 60, max_bytes: 30_000_000)
          if r.code == 200
            data = JSON.parse(r.body)
            if data['remark'].to_s =~ /runtime error|timed out/i && (data['elements'] || []).empty?
              errors << "#{URI(url).host}: #{data['remark'][0, 80]}"
              data = nil
              next
            end
            break
          end
          errors << "#{URI(url).host}: HTTP #{r.code}"
          sleep 5 if i.zero? && [429, 504].include?(r.code)
        rescue HttpClient::Error, JSON::ParserError => e
          errors << "#{URI(url).host}: #{e.message}"
        end
      end
    end
    raise HttpClient::Error, "OpenStreetMap no respondió (#{errors.join('; ')})" unless data
    (data['elements'] || []).map { |el| to_company(el, area) }.compact
  end

  def self.osm_url(el)
    "https://www.openstreetmap.org/#{el['type']}/#{el['id']}"
  end

  def self.to_company(el, area)
    t = el['tags'] || {}
    return nil if t['name'].to_s.strip.empty?
    return nil if t.keys.any? { |k| k.start_with?('disused:', 'abandoned:') } || t['opening_hours'] == 'closed'
    src = osm_url(el)
    street = [t['addr:street'], t['addr:housenumber']].compact.join(' ')
    c = {
      name: t['name'].strip,
      sector: Sectors.label_from_tags(t),
      sector_tags: t.select { |k, _| %w[shop office amenity craft healthcare tourism leisure sport].include?(k) },
      address: street.empty? ? nil : street,
      postcode: t['addr:postcode'],
      city: t['addr:city'] || (area[:mode] == :area && %w[city town village municipality].include?(area[:addresstype]) ? area[:city] : nil),
      province: t['addr:province'] || (area_fixed?(area) ? area[:province] : nil),
      region: t['addr:state'] || (area_fixed?(area) ? area[:region] : nil),
      country: area[:country] || 'España',
      lat: el['lat'] || (el['center'] && el['center']['lat']),
      lon: el['lon'] || (el['center'] && el['center']['lon']),
      website: t['website'] || t['contact:website'] || t['url'],
      phone: t['phone'] || t['contact:phone'] || t['contact:mobile'],
      email: t['email'] || t['contact:email'],
      instagram: t['contact:instagram'] || t['instagram'],
      facebook: t['contact:facebook'] || t['facebook'],
      linkedin: t['contact:linkedin'],
      opening_hours: t['opening_hours'],
      employees: t['employees'],
      osm_ref: src,
      field_sources: {}
    }
    %i[name address postcode city website phone email instagram facebook linkedin opening_hours employees].each do |f|
      c[:field_sources][f.to_s] = { 'source' => 'OpenStreetMap', 'url' => src } if c[f]
    end
    %i[province region].each do |f|
      next unless c[f]
      c[:field_sources][f.to_s] = { 'source' => t["addr:#{f == :region ? 'state' : 'province'}"] ? 'OpenStreetMap' : 'Nominatim (área de búsqueda)', 'url' => src }
    end
    c
  end

  # La provincia/comunidad del área solo se aplica a cada negocio si el área es una ciudad o provincia.
  def self.area_fixed?(area)
    %w[city town village municipality county province suburb city_district quarter neighbourhood postcode].include?(area[:addresstype]) || area[:mode] == :around
  end
end
