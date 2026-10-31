# Persistencia de empresas, filtros, mini CRM y controles RGPD.
module Companies
  STATUSES = ['Nuevo lead', 'Pendiente de contactar', 'Primer contacto realizado', 'Seguimiento pendiente', 'Ha respondido',
              'Interesado', 'Reunión concertada', 'Cliente conseguido', 'No interesado'].freeze
  DATA_FIELDS = %i[name sector address postcode city province region country lat lon website instagram facebook linkedin tiktok
                   phone email whatsapp employees opening_hours google_place_id osm_ref maps_url rating rating_count business_status].freeze

  def self.upsert(c, analysis, ops, s, ctx)
    key = Search.dedup_key(c)
    now = DB.now
    existing = DB.one('SELECT * FROM companies WHERE dedup_key = ?', [key])
    sources = c[:field_sources] || {}
    source_note = "Encontrada en: #{(c[:found_in] || []).join(' + ')}#{analysis && analysis['reachable'] ? ' + web del propio negocio' : ''}. Primera detección #{now[0, 10]}."
    values = DATA_FIELDS.map { |f| v = c[f]; v.is_a?(String) ? v.strip[0, 500] : v }
    if existing
      old_sources = (JSON.parse(existing['field_sources'] || '{}') rescue {})
      merged = DATA_FIELDS.each_with_index.map { |f, i| values[i].nil? || values[i] == '' ? existing[f.to_s] : values[i] }
      sets = DATA_FIELDS.map { |f| "#{f} = ?" }.join(', ')
      DB.run("UPDATE companies SET #{sets}, sector_tags = ?, field_sources = ?, analysis = ?, opportunities = ?, score = ?, score_breakdown = ?,
              score_explanation = ?, score_tier = ?, score_context = ?, confidence = ?, last_checked_at = ?, updated_at = ? WHERE id = ?",
             merged + [JSON.generate(c[:sector_tags] || {}), JSON.generate(old_sources.merge(sources)), JSON.generate(analysis || {}),
                       JSON.generate(ops), s[:score], JSON.generate(s[:breakdown]), s[:explanation], s[:tier], JSON.generate(ctx),
                       Scoring.confidence(c, analysis), now, now, existing['id']])
      existing['id']
    else
      cols = DATA_FIELDS.map(&:to_s) + %w[dedup_key sector_tags field_sources analysis opportunities score score_breakdown score_explanation
                                          score_tier score_context confidence lawful_basis source_note last_checked_at created_at updated_at]
      DB.run("INSERT INTO companies(#{cols.join(', ')}) VALUES (#{(['?'] * cols.size).join(', ')})",
             values + [key, JSON.generate(c[:sector_tags] || {}), JSON.generate(sources), JSON.generate(analysis || {}), JSON.generate(ops),
                       s[:score], JSON.generate(s[:breakdown]), s[:explanation], s[:tier], JSON.generate(ctx), Scoring.confidence(c, analysis),
                       DB.setting('default_lawful_basis'), source_note, now, now, now])
    end
  end

  # Filtros comunes para resultados y base de datos de leads.
  def self.where_clause(f)
    conds = []
    params = []
    { 'country' => 'country', 'region' => 'region', 'province' => 'province', 'city' => 'city', 'postcode' => 'postcode', 'sector' => 'sector' }.each do |k, col|
      next if f[k].to_s.strip.empty?
      conds << "LOWER(COALESCE(#{col}, '')) LIKE ?"
      params << "%#{f[k].to_s.strip.downcase}%"
    end
    { 'website' => 'website', 'instagram' => 'instagram', 'email' => 'email', 'phone' => 'phone' }.each do |k, col|
      conds << "COALESCE(#{col}, '') <> ''" if f[k] == 'con'
      conds << "COALESCE(#{col}, '') = ''" if f[k] == 'sin'
    end
    if f['employees'] == 'conocido'
      conds << "COALESCE(employees, '') <> ''"
    end
    if f['min_score'].to_i > 0
      conds << 'score >= ?'
      params << f['min_score'].to_i
    end
    if f['max_score'].to_s =~ /\A\d+\z/ && f['max_score'].to_i < 100
      conds << 'score <= ?'
      params << f['max_score'].to_i
    end
    unless f['status'].to_s.empty?
      conds << 'status = ?'
      params << f['status']
    end
    unless f['q'].to_s.strip.empty?
      conds << "(LOWER(name) LIKE ? OR LOWER(COALESCE(city,'')) LIKE ? OR LOWER(COALESCE(sector,'')) LIKE ?)"
      3.times { params << "%#{f['q'].strip.downcase}%" }
    end
    conds << 'saved = 0' if f['exclude_saved'] == '1'
    [conds, params]
  end

  SORTS = { 'score' => 'score DESC, name', 'name' => 'name COLLATE NOCASE', 'city' => 'city, name', 'recent' => 'updated_at DESC',
            'status' => 'status, score DESC', 'next_action' => "CASE WHEN next_action_date IS NULL OR next_action_date = '' THEN 1 ELSE 0 END, next_action_date" }.freeze

  def self.list(f, search_id: nil, saved_only: false)
    conds, params = where_clause(f)
    from = 'companies'
    if search_id
      from = 'companies JOIN search_results sr ON sr.company_id = companies.id'
      conds << 'sr.search_id = ?'
      params << search_id
    end
    conds << 'saved = 1' if saved_only
    sql = "SELECT companies.* FROM #{from}#{conds.empty? ? '' : ' WHERE ' + conds.join(' AND ')} ORDER BY #{SORTS[f['sort']] || SORTS['score']}"
    DB.all(sql, params).map { |r| DB.decode(r) }
  end

  def self.get(id)
    DB.decode(DB.one('SELECT * FROM companies WHERE id = ?', [id]))
  end

  def self.add_event(id, kind, text, date = nil)
    DB.run('INSERT INTO crm_events(company_id, kind, text, event_date, created_at) VALUES (?, ?, ?, ?, ?)', [id, kind, text, date, DB.now])
    DB.run('UPDATE companies SET updated_at = ? WHERE id = ?', [DB.now, id])
  end

  def self.events(id)
    DB.all('SELECT * FROM crm_events WHERE company_id = ? ORDER BY created_at DESC, id DESC', [id])
  end

  EDITABLE = %w[status next_action next_action_date last_contact_date decision_maker decision_maker_source lawful_basis employees].freeze

  def self.update(id, data)
    c = get(id)
    raise ArgumentError, 'Empresa no encontrada' unless c
    if data.key?('status') && !STATUSES.include?(data['status'])
      raise ArgumentError, 'Estado comercial no válido'
    end
    if data.key?('decision_maker') && !data['decision_maker'].to_s.strip.empty? && data['decision_maker_source'].to_s.strip.empty?
      raise ArgumentError, 'Indica de qué fuente pública sale el nombre del decisor (p. ej., la web «Quiénes somos»)'
    end
    changes = data.select { |k, _| EDITABLE.include?(k) }
    return c if changes.empty?
    DB.run("UPDATE companies SET #{changes.keys.map { |k| "#{k} = ?" }.join(', ')}, updated_at = ? WHERE id = ?", changes.values.map { |v| v.to_s.strip[0, 2000] } + [DB.now, id])
    if changes['status'] && changes['status'] != c['status']
      add_event(id, 'estado', "Estado: #{c['status']} → #{changes['status']}")
      if changes['status'] != 'Nuevo lead' && c['saved'].to_i.zero?
        set_saved(id, true) # trabajar un lead lo guarda automáticamente
      end
    end
    add_event(id, 'accion', "Próxima acción: #{changes['next_action']} #{changes['next_action_date']}".strip) if changes['next_action'] && changes['next_action'] != c['next_action'] && !changes['next_action'].to_s.empty?
    add_event(id, 'contacto', "Fecha de contacto registrada: #{changes['last_contact_date']}") if changes['last_contact_date'] && changes['last_contact_date'] != c['last_contact_date'] && !changes['last_contact_date'].to_s.empty?
    add_event(id, 'decisor', "Decisor: #{changes['decision_maker']} (fuente: #{changes['decision_maker_source']})") if changes['decision_maker'] && changes['decision_maker'] != c['decision_maker']
    get(id)
  end

  def self.set_saved(id, saved)
    DB.run('UPDATE companies SET saved = ?, saved_at = ?, updated_at = ? WHERE id = ?', [saved ? 1 : 0, saved ? DB.now : nil, DB.now, id])
    add_event(id, 'sistema', saved ? 'Guardada en la base de leads' : 'Quitada de la base de leads')
  end

  # Derecho de supresión (RGPD art. 17): borra todos los datos y añade a la lista de exclusión
  # para que no vuelva a importarse en futuras búsquedas.
  def self.suppress(id, reason)
    c = get(id)
    raise ArgumentError, 'Empresa no encontrada' unless c
    sym = c.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
    DB.transaction do
      Search.suppression_keys(sym).each do |k|
        DB.run('INSERT OR IGNORE INTO suppression(key, label, reason, created_at) VALUES (?, ?, ?, ?)', [k, c['name'], reason.to_s[0, 500], DB.now])
      end
      delete_all_data(id)
    end
    DB.audit('supresion', "Solicitud de supresión atendida: #{c['name']} (#{c['city']}). Motivo: #{reason}")
  end

  def self.delete_all_data(id)
    DB.run('DELETE FROM crm_events WHERE company_id = ?', [id])
    DB.run('DELETE FROM drafts WHERE company_id = ?', [id])
    DB.run('DELETE FROM search_results WHERE company_id = ?', [id])
    DB.run('DELETE FROM companies WHERE id = ?', [id])
  end

  # Política de conservación: elimina resultados no guardados y leads guardados sin actividad pasado el plazo.
  def self.apply_retention!
    unsaved = DB.setting('retention_days_unsaved').to_i
    saved = DB.setting('retention_days_saved').to_i
    removed = 0
    if unsaved > 0
      cutoff = (Time.now.utc - unsaved * 86_400).strftime('%Y-%m-%dT%H:%M:%SZ')
      DB.all('SELECT id FROM companies WHERE saved = 0 AND updated_at < ?', [cutoff]).each { |r| delete_all_data(r['id']); removed += 1 }
    end
    if saved > 0
      cutoff = (Time.now.utc - saved * 86_400).strftime('%Y-%m-%dT%H:%M:%SZ')
      DB.all("SELECT id FROM companies WHERE saved = 1 AND updated_at < ? AND status <> 'Cliente conseguido'", [cutoff]).each { |r| delete_all_data(r['id']); removed += 1 }
    end
    DB.audit('conservacion', "Limpieza automática: #{removed} registros eliminados") if removed > 0
    removed
  end

  def self.stats
    total_saved = DB.one('SELECT COUNT(*) n FROM companies WHERE saved = 1')['n']
    by_status = DB.all('SELECT status, COUNT(*) n FROM companies WHERE saved = 1 GROUP BY status')
    by_tier = DB.all('SELECT score_tier tier, COUNT(*) n FROM companies WHERE saved = 1 GROUP BY score_tier')
    by_sector = DB.all('SELECT COALESCE(sector, \'No encontrado\') sector, COUNT(*) n, ROUND(AVG(score)) avg FROM companies WHERE saved = 1 GROUP BY sector ORDER BY n DESC LIMIT 8')
    by_city = DB.all('SELECT COALESCE(city, \'No encontrado\') city, COUNT(*) n FROM companies WHERE saved = 1 GROUP BY city ORDER BY n DESC LIMIT 8')
    {
      saved: total_saved,
      total_companies: DB.one('SELECT COUNT(*) n FROM companies')['n'],
      searches: DB.one('SELECT COUNT(*) n FROM searches')['n'],
      avg_score: DB.one('SELECT ROUND(AVG(score)) a FROM companies WHERE saved = 1')['a'],
      with_email: DB.one("SELECT COUNT(*) n FROM companies WHERE saved = 1 AND COALESCE(email,'') <> ''")['n'],
      without_web: DB.one("SELECT COUNT(*) n FROM companies WHERE saved = 1 AND COALESCE(website,'') = ''")['n'],
      won: DB.one("SELECT COUNT(*) n FROM companies WHERE status = 'Cliente conseguido'")['n'],
      meetings: DB.one("SELECT COUNT(*) n FROM companies WHERE status = 'Reunión concertada'")['n'],
      drafts: DB.one('SELECT COUNT(*) n FROM drafts')['n'],
      due: DB.all("SELECT id, name, next_action, next_action_date, status FROM companies WHERE saved = 1 AND COALESCE(next_action_date,'') <> '' AND next_action_date <= ? ORDER BY next_action_date LIMIT 10", [(Date.today + 7).to_s]),
      by_status: by_status, by_tier: by_tier, by_sector: by_sector, by_city: by_city
    }
  end
end
