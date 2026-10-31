# Orquesta una búsqueda: geocodifica, consulta fuentes reales, deduplica, analiza webs y puntúa.
# Se ejecuta en segundo plano; la interfaz consulta el progreso.
module Search
  MAX_LEADS = 150
  WORKERS = 8

  def self.progress(id, pct, msg)
    DB.run('UPDATE searches SET progress = ?, message = ? WHERE id = ?', [pct, msg, id])
  end

  def self.norm_name(name)
    Sectors.normalize(name).gsub(/[^a-z0-9 ]/, ' ').gsub(/\b(s\.?l\.?u?|s\.?a\.?|sl|sa|slp|cb)\b/, '').split.join(' ')
  end

  def self.digits(phone)
    d = phone.to_s.gsub(/\D/, '')
    d = d[2..-1] if d.start_with?('34') && d.length == 11
    d.empty? ? nil : d
  end

  def self.dedup_key(c)
    "n:#{norm_name(c[:name])}|#{c[:postcode] || Sectors.normalize(c[:city].to_s)}"
  end

  def self.suppression_keys(c)
    keys = ["name:#{norm_name(c[:name])}|#{Sectors.normalize(c[:city].to_s)}"]
    d = Analyzer.domain(c[:website]) if c[:website]
    keys << "domain:#{d}" if d && !d.empty?
    keys << "phone:#{digits(c[:phone])}" if digits(c[:phone])
    keys << "email:#{c[:email].to_s.downcase}" unless c[:email].to_s.empty?
    keys
  end

  def self.suppressed?(c)
    keys = suppression_keys(c)
    !DB.one("SELECT 1 FROM suppression WHERE key IN (#{(['?'] * keys.size).join(',')}) LIMIT 1", keys).nil?
  end

  def self.close?(a, b)
    return false unless a[:lat] && b[:lat]
    dlat = (a[:lat].to_f - b[:lat].to_f) * 111_000
    dlon = (a[:lon].to_f - b[:lon].to_f) * 111_000 * Math.cos(a[:lat].to_f * Math::PI / 180)
    Math.sqrt(dlat**2 + dlon**2) < 200
  end

  # Fusiona candidatos de varias fuentes: mismo nombre normalizado y cercanos, o mismo teléfono.
  def self.merge(lists)
    merged = []
    lists.each do |source, items|
      items.each do |c|
        c[:found_in] = [source]
        twin = merged.find do |m|
          (norm_name(m[:name]) == norm_name(c[:name]) &&
            (close?(m, c) || ((m[:lat].nil? || c[:lat].nil?) && m[:postcode] && m[:postcode] == c[:postcode]))) ||
            (digits(m[:phone]) && digits(m[:phone]) == digits(c[:phone]))
        end
        if twin
          c.each do |k, v|
            next if v.nil? || v == '' || %i[found_in field_sources].include?(k)
            twin[k] = v if twin[k].nil? || twin[k] == ''
          end
          c[:field_sources].each { |f, s| twin[:field_sources][f] ||= s }
          twin[:found_in] |= [source]
        else
          merged << c
        end
      end
    end
    merged
  end

  def self.enrich(c)
    c[:website] = Analyzer.normalize_url(c[:website]) if c[:website]
    analysis = nil
    if c[:website]
      analysis = Analyzer.analyze(c[:website])
      if analysis['reachable']
        src = { 'source' => 'Web del negocio', 'url' => analysis['source_url'] }
        if c[:email].to_s.empty? && analysis['emails'].any?
          c[:email] = analysis['emails'].first
          c[:field_sources]['email'] = { 'source' => 'Web del negocio', 'url' => analysis['email_source_url'] || analysis['source_url'] }
        end
        if c[:phone].to_s.empty? && analysis['phones'].any?
          c[:phone] = analysis['phones'].first
          c[:field_sources]['phone'] = src
        end
        %w[instagram facebook linkedin tiktok].each do |net|
          v = analysis['social'][net]
          next if v.nil? || !c[net.to_sym].to_s.empty?
          c[net.to_sym] = v
          c[:field_sources][net] = src
        end
        if analysis['has_whatsapp']
          c[:whatsapp] = analysis['whatsapp_number'] || 'Enlace de WhatsApp publicado en la web'
          c[:field_sources]['whatsapp'] = src
        end
      end
    end
    [c, analysis]
  end

  def self.run(search_id, p)
    started = Time.now
    limit = [[p['limit'].to_i, 1].max, MAX_LEADS].min
    progress(search_id, 5, 'Localizando la zona en el mapa…')
    area = Nominatim.resolve_location(p['location'].to_s, postcode: p['postcode'].to_s.strip)
    DB.run('UPDATE searches SET location_label = ? WHERE id = ?', [area[:label], search_id])

    sector = Sectors.resolve(p['sector']) || { term: p['sector'].to_s }
    raise HttpClient::Error, 'Indica un sector o tipo de negocio' if sector[:term] && sector[:term].strip.empty?

    lists = []
    used = []
    errors = []
    if GooglePlaces.enabled?
      progress(search_id, 15, 'Buscando en Google Places…')
      begin
        q = "#{p['sector']} en #{p['postcode'].to_s.empty? ? p['location'] : "#{p['postcode']} #{p['location']}"}"
        lists << ['Google Places', GooglePlaces.search(q, limit)]
        used << 'Google Places'
      rescue HttpClient::Error => e
        errors << e.message
      end
    end
    # Overpass (más completo pero a veces saturado) corre en paralelo, con un tiempo máximo;
    # mientras tanto se consulta Nominatim, que es rápido.
    progress(search_id, 20, 'Buscando negocios en OpenStreetMap (puede tardar hasta 1-2 minutos)…')
    overpass = Thread.new do
      begin
        [:ok, Overpass.search(area, sector, limit)]
      rescue HttpClient::Error => e
        [:error, e.message]
      end
    end
    osm = []
    begin
      osm.concat(Nominatim.search_pois(area, sector, limit))
    rescue HttpClient::Error => e
      errors << "Nominatim: #{e.message}"
    end
    progress(search_id, 28, "#{osm.size} negocios desde Nominatim. Esperando a Overpass…")
    if overpass.join(Env.int('OVERPASS_MAX_WAIT', 130))
      status, value = overpass.value
      status == :ok ? osm.concat(value) : errors << value
    else
      errors << 'Overpass tardó demasiado; se han usado solo los resultados de Nominatim'
    end
    unless osm.empty?
      lists << ['OpenStreetMap', osm]
      used << 'OpenStreetMap'
    end
    raise HttpClient::Error, "Ninguna fuente respondió: #{errors.join(' | ')}" if used.empty?

    candidates = merge(lists)
    total_raw = candidates.size

    # Filtros que se pueden aplicar antes de analizar las webs
    candidates.select! { |c| c[:postcode].nil? || c[:postcode] == p['postcode'] } unless p['postcode'].to_s.strip.empty?
    candidates.select! { |c| c[:city].nil? || Sectors.normalize(c[:city]).include?(Sectors.normalize(p['city'])) } unless p['city'].to_s.strip.empty?
    candidates.select! { |c| !c[:website].to_s.empty? } if p['website'] == 'con'
    candidates.select! { |c| c[:website].to_s.empty? } if p['website'] == 'sin'
    candidates.reject! { |c| suppressed?(c) }
    if p['exclude_saved']
      saved = DB.all('SELECT dedup_key FROM companies WHERE saved = 1').map { |r| r['dedup_key'] }
      candidates.reject! { |c| saved.include?(dedup_key(c)) }
    end
    # Primero los que tienen más datos verificables
    candidates.sort_by! { |c| [-(c[:found_in].size), c[:website] ? 0 : 1, c[:name]] }
    needs_enrichment_filters = %w[instagram email].any? { |k| %w[con sin].include?(p[k]) } || p['min_score'].to_i > 0
    pool = candidates.first(needs_enrichment_filters ? [limit * 3, 200].min : limit)

    progress(search_id, 35, "#{total_raw} negocios encontrados. Analizando sus webs (0/#{pool.size})…")
    results = []
    queue = Queue.new
    pool.each { |c| queue << c }
    done = 0
    lock = Mutex.new
    threads = Array.new([WORKERS, pool.size].min) do
      Thread.new do
        loop do
          c = begin
            queue.pop(true)
          rescue ThreadError
            nil
          end
          break unless c
          enriched, analysis = begin
            enrich(c)
          rescue StandardError => e
            [c, { 'reachable' => false, 'error' => e.message[0, 150] }]
          end
          lock.synchronize do
            results << [enriched, analysis]
            done += 1
            progress(search_id, 35 + (done * 55 / [pool.size, 1].max), "Analizando webs (#{done}/#{pool.size})…")
          end
        end
      end
    end
    threads.each(&:join)

    ctx = { 'offer' => p['offer'], 'customer_type' => p['customer_type'], 'ideal' => p['ideal'] }
    progress(search_id, 92, 'Calculando puntuaciones…')
    scored = results.map do |c, analysis|
      ops = Scoring.opportunities(c, analysis)
      s = Scoring.score(c, analysis, ops, ctx)
      [c, analysis, ops, s]
    end
    scored.select! { |c, _, _, _| !c[:instagram].to_s.empty? } if p['instagram'] == 'con'
    scored.select! { |c, _, _, _| c[:instagram].to_s.empty? } if p['instagram'] == 'sin'
    scored.select! { |c, _, _, _| !c[:email].to_s.empty? } if p['email'] == 'con'
    scored.select! { |c, _, _, _| c[:email].to_s.empty? } if p['email'] == 'sin'
    scored.select! { |_, _, _, s| s[:score] >= p['min_score'].to_i } if p['min_score'].to_i > 0
    scored = scored.sort_by { |_, _, _, s| -s[:score] }.first(limit)

    DB.transaction do
      scored.each_with_index do |(c, analysis, ops, s), i|
        id = Companies.upsert(c, analysis, ops, s, ctx)
        DB.run('INSERT OR IGNORE INTO search_results(search_id, company_id, position) VALUES (?, ?, ?)', [search_id, id, i])
      end
    end
    msg = "Completada en #{(Time.now - started).round}s: #{scored.size} empresas (#{total_raw} encontradas en total)."
    msg += " Aviso: #{errors.join(' | ')}" if errors.any?
    msg += ' Ningún resultado: prueba con otra zona, otro sector o menos filtros.' if scored.empty?
    DB.run("UPDATE searches SET status = 'completada', progress = 100, message = ?, total_found = ?, sources_used = ?, finished_at = ? WHERE id = ?",
           [msg, scored.size, JSON.generate(used), DB.now, search_id])
  rescue StandardError => e
    warn "[búsqueda #{search_id}] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
    DB.run("UPDATE searches SET status = 'error', message = ?, finished_at = ? WHERE id = ?", ["Error: #{e.message}", DB.now, search_id])
  end
end
