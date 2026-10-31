# Asistente comercial con Claude (API de Anthropic, llamada HTTP directa: el SDK oficial de Ruby
# necesita una versión de Ruby más moderna que la que trae macOS).
# Genera borradores que el usuario revisa y aprueba. Nunca envía nada.
module AI
  URL = 'https://api.anthropic.com/v1/messages'.freeze
  KINDS = {
    'por_que' => 'Por qué podría necesitar tu servicio',
    'dm_instagram' => 'Mensaje directo de Instagram',
    'email' => 'Email comercial',
    'whatsapp' => 'Mensaje de WhatsApp Business',
    'propuesta' => 'Propuesta inicial',
    'argumentario' => 'Argumentario de venta'
  }.freeze

  SCHEMA = {
    'type' => 'object',
    'additionalProperties' => false,
    'required' => %w[por_que dm_instagram email_asunto email_cuerpo whatsapp propuesta argumentario],
    'properties' => {
      'por_que' => { 'type' => 'string' },
      'dm_instagram' => { 'type' => 'string' },
      'email_asunto' => { 'type' => 'string' },
      'email_cuerpo' => { 'type' => 'string' },
      'whatsapp' => { 'type' => 'string' },
      'propuesta' => { 'type' => 'string' },
      'argumentario' => { 'type' => 'string' }
    }
  }.freeze

  SYSTEM = <<~TXT.freeze
    Eres un asistente comercial para un profesional que vende servicios a pequeñas empresas en España.
    Escribe en español de España, con tono cercano, profesional y sin exageraciones. Usa «tú» salvo que el sector sugiera «usted» (despachos de abogados, notarías, clínicas médicas).

    Reglas estrictas:
    - Usa EXCLUSIVAMENTE los datos de la empresa y las evidencias que se te proporcionan. No inventes datos, cifras, nombres de personas, reseñas, clientes, premios ni resultados.
    - Si un dato aparece como «No encontrado», no lo menciones ni lo supongas.
    - Distingue hechos de hipótesis: las oportunidades son observaciones de su presencia pública («he visto que…»), nunca afirmaciones sobre su negocio interno.
    - No prometas resultados garantizados.
    - Los mensajes son para un primer contacto individual: breves, personalizados, con una sola llamada a la acción suave y una forma fácil de decir que no.
    - El email debe incluir al final una línea indicando cómo dejar de recibir comunicaciones.
    - Si se indica que NO hay base para WhatsApp, devuelve en «whatsapp» exactamente: NO_APLICA
    - Usa los datos del remitente tal cual; si faltan, deja marcadores entre corchetes como [Tu nombre].

    Campos:
    - por_que: 3-5 viñetas con por qué podría necesitar el servicio, cada una apoyada en una evidencia concreta.
    - dm_instagram: máx. 450 caracteres.
    - email_asunto y email_cuerpo: email de 90-160 palabras.
    - whatsapp: máx. 350 caracteres.
    - propuesta: propuesta inicial en 4-6 puntos (diagnóstico, qué harías, siguiente paso). Sin precios salvo que el remitente los indique.
    - argumentario: guion breve para una llamada o visita: apertura, 3 argumentos basados en evidencias, 3 objeciones probables con respuesta, cierre.
  TXT

  def self.enabled?
    !Env.get('ANTHROPIC_API_KEY').nil?
  end

  def self.model
    Env.get('ANTHROPIC_MODEL', 'claude-opus-5-5')
  end

  def self.facts(c)
    nf = 'No encontrado'
    analysis = c['analysis'].is_a?(Hash) ? c['analysis'] : {}
    {
      'nombre' => c['name'], 'sector' => c['sector'] || nf, 'ciudad' => c['city'] || nf, 'direccion' => c['address'] || nf,
      'web' => c['website'] || nf, 'instagram' => c['instagram'] || nf, 'facebook' => c['facebook'] || nf, 'linkedin' => c['linkedin'] || nf,
      'telefono_publico' => c['phone'] || nf, 'email_publico' => c['email'] || nf, 'decisor_publico' => c['decision_maker'] || nf,
      'valoracion_google' => c['rating'] ? "#{c['rating']} (#{c['rating_count']} reseñas)" : nf,
      'titulo_web' => analysis['title'].to_s.empty? ? nf : analysis['title'],
      'descripcion_web' => analysis['description'].to_s.empty? ? nf : analysis['description'],
      'oportunidades_con_evidencia' => (c['opportunities'] || []).map { |o| "#{o['title']}: #{o['evidence']}" },
      'puntuacion' => "#{c['score']}/100 (#{c['score_tier']})"
    }
  end

  def self.generate(company)
    raise ArgumentError, 'Falta ANTHROPIC_API_KEY en el archivo .env (ver README, apartado «Asistente IA»).' unless enabled?
    s = DB.settings
    ctx = company['score_context'].is_a?(Hash) ? company['score_context'] : {}
    whatsapp_ok = !company['whatsapp'].to_s.empty?
    prompt = <<~TXT
      DATOS DEL REMITENTE
      Nombre: #{s['sender_name'].to_s.empty? ? '[Tu nombre]' : s['sender_name']}
      Empresa: #{s['sender_company'].to_s.empty? ? '[Tu empresa]' : s['sender_company']}
      Qué vende: #{[ctx['offer'], s['sender_offer']].reject { |x| x.to_s.strip.empty? }.first || '[Tu servicio]'}
      Cliente ideal: #{ctx['ideal'].to_s.empty? ? 'No indicado' : ctx['ideal']}

      BASE PARA WHATSAPP: #{whatsapp_ok ? 'Sí: el negocio publica un enlace de WhatsApp para contacto en su web.' : 'NO: el negocio no publica WhatsApp como canal de contacto. Devuelve NO_APLICA.'}

      DATOS PÚBLICOS DE LA EMPRESA (JSON)
      #{JSON.pretty_generate(facts(company))}
    TXT
    body = {
      model: model,
      max_tokens: 16_000,
      system: SYSTEM,
      output_config: { effort: 'medium', format: { type: 'json_schema', schema: SCHEMA } },
      messages: [{ role: 'user', content: prompt }]
    }
    fallback = model =~ /opus-5|fable-5|sonnet-5-5/
    body[:fallbacks] = 'default' if fallback
    headers = {
      'Content-Type' => 'application/json',
      'x-api-key' => Env.get('ANTHROPIC_API_KEY'),
      'anthropic-version' => Env.get('ANTHROPIC_VERSION', '2026-10-21')
    }
    headers['anthropic-beta'] = 'server-side-fallback-2026-07-01' if fallback
    r = HttpClient.request(:post, URL, body: JSON.generate(body), headers: headers, timeout: 180, max_bytes: 5_000_000)
    data = (JSON.parse(r.body) rescue {})
    unless r.code == 200
      msg = data.dig('error', 'message') || "HTTP #{r.code}"
      hint = { 401 => ' (la clave API no es válida)', 429 => ' (límite de uso alcanzado, espera un poco)', 529 => ' (servicio saturado, reintenta)' }[r.code]
      raise ArgumentError, "Error de la API de Claude: #{msg}#{hint}"
    end
    raise ArgumentError, 'Claude rechazó generar este contenido.' if data['stop_reason'] == 'refusal'
    raise ArgumentError, 'La respuesta se cortó; inténtalo de nuevo.' if data['stop_reason'] == 'max_tokens'
    text = (data['content'] || []).select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join
    out = JSON.parse(text)
    used_model = data['model'] || model
    now = DB.now
    saved = []
    DB.transaction do
      add = lambda do |kind, content|
        DB.run('INSERT INTO drafts(company_id, kind, title, content, status, model, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
               [company['id'], kind, KINDS[kind], content, 'borrador', used_model, now, now])
        saved << kind
      end
      add.call('por_que', out['por_que'])
      add.call('dm_instagram', out['dm_instagram'])
      add.call('email', "Asunto: #{out['email_asunto']}\n\n#{out['email_cuerpo']}")
      add.call('whatsapp', out['whatsapp']) if whatsapp_ok && out['whatsapp'].strip != 'NO_APLICA'
      add.call('propuesta', out['propuesta'])
      add.call('argumentario', out['argumentario'])
    end
    Companies.add_event(company['id'], 'ia', "Borradores generados con IA (#{used_model}): #{saved.map { |k| KINDS[k] }.join(', ')}")
    saved
  rescue JSON::ParserError
    raise ArgumentError, 'La respuesta de la IA no tenía el formato esperado; inténtalo de nuevo.'
  end
end
