# Detección de oportunidades (solo con evidencias públicas) y puntuación 0-100 explicada.
module Scoring
  TIERS = [[80, 'Prioritario'], [60, 'Interesante'], [40, 'Secundario'], [0, 'Baja prioridad']].freeze

  # Qué tipo de servicio vende el usuario, deducido de su descripción.
  OFFER_TYPES = {
    'web' => /\b(web|p[aá]gina|landing|wordpress|dise[nñ]o web|tienda online|ecommerce|e-commerce|sitio)/i,
    'redes' => /(redes sociales|instagram|social media|community|contenido|tiktok|reels|facebook)/i,
    'marketing' => /(seo|google|posicionamiento|marketing|publicidad|ads|anuncios|captaci[oó]n|branding|rese[nñ]as)/i,
    'automatizacion' => /(automatiz|chatbot|bot\b|\bia\b|inteligencia artificial|crm|reservas|citas|whatsapp|software|app)/i
  }.freeze

  def self.offer_types(offer)
    types = OFFER_TYPES.select { |_, rx| offer.to_s =~ rx }.keys
    types.empty? ? ['general'] : types
  end

  # Cada oportunidad: código, título, evidencia, peso por tipo de servicio.
  def self.opportunities(c, analysis)
    ops = []
    year = Time.now.year
    social = (analysis && analysis['social']) || {}
    has_web = !c[:website].to_s.empty?
    if !has_web
      ops << op('sin_web', 'Sin web encontrada', "Ninguna fuente consultada (#{(c[:found_in] || []).join(', ')}) indica una página web.",
                'web' => 30, 'marketing' => 15, 'automatizacion' => 10, 'redes' => 5, 'general' => 15)
    elsif analysis && analysis['reachable'] == false
      ops << op('web_caida', 'La web no carga', "Al visitar #{c[:website]} el #{fmt_date(analysis['checked_at'])}: #{analysis['error']}.",
                'web' => 25, 'marketing' => 15, 'general' => 12)
    elsif analysis && analysis['reachable']
      if analysis['https'] == false
        ops << op('sin_https', 'Web sin HTTPS', "#{analysis['final_url']} se sirve sin cifrado (http://).", 'web' => 12, 'marketing' => 8, 'general' => 6)
      elsif analysis['cert_valid'] == false
        ops << op('cert_invalido', 'Certificado HTTPS no válido', 'El navegador mostraría un aviso de seguridad al entrar.', 'web' => 12, 'marketing' => 6, 'general' => 6)
      end
      unless analysis['viewport']
        ops << op('no_movil', 'Web no adaptada a móvil', 'La página no declara la etiqueta «viewport» para móviles.', 'web' => 15, 'marketing' => 8, 'general' => 6)
      end
      if analysis['copyright_year'] && analysis['copyright_year'] <= year - 3
        ops << op('web_antigua', 'Web posiblemente desactualizada', "El pie de página indica © #{analysis['copyright_year']}.", 'web' => 12, 'marketing' => 6, 'redes' => 3, 'general' => 6)
      end
      if social.empty? && c[:instagram].to_s.empty? && c[:facebook].to_s.empty?
        ops << op('sin_redes', 'Web sin enlaces a redes sociales', 'No se encontraron enlaces a Instagram, Facebook, LinkedIn ni TikTok en la web ni en las fuentes.',
                  'redes' => 22, 'marketing' => 10, 'general' => 6)
      elsif c[:instagram].to_s.empty? && social['instagram'].nil?
        ops << op('sin_instagram', 'Sin Instagram localizado', 'No se encontró perfil de Instagram en la web ni en las fuentes consultadas.', 'redes' => 15, 'marketing' => 5, 'general' => 4)
      end
      unless analysis['has_booking']
        ops << op('sin_reservas', 'Sin reserva o cita online visible', 'La web no muestra sistema de reservas/citas online.', 'automatizacion' => 15, 'web' => 6, 'general' => 5)
      end
      unless analysis['has_contact_form']
        ops << op('sin_formulario', 'Sin formulario de contacto en la web', 'No se detectó un formulario de contacto en la portada ni en la página de contacto.', 'web' => 6, 'automatizacion' => 8, 'general' => 3)
      end
      if analysis['builder'] && %w[Wix Jimdo Webnode].include?(analysis['builder'])
        ops << op('web_plantilla', "Web hecha con #{analysis['builder']}", "Construida con un creador de webs básico (#{analysis['builder']}).", 'web' => 6, 'general' => 2)
      end
    end
    # Sin web que revisar: solo podemos afirmar que las fuentes no listan redes sociales.
    if (analysis.nil? || analysis['reachable'] != true) && c[:instagram].to_s.empty? && c[:facebook].to_s.empty?
      ops << op('sin_redes_fuentes', 'Sin redes sociales localizadas', "Las fuentes consultadas (#{(c[:found_in] || []).join(', ')}) no indican Instagram ni Facebook y no hay web donde comprobarlo.",
                'redes' => 15, 'marketing' => 5, 'general' => 3)
    end
    if c[:email].to_s.empty?
      ops << op('sin_email', 'Sin email público encontrado', 'No hay email publicado en las fuentes ni en la web.', 'automatizacion' => 4, 'web' => 4, 'general' => 3)
    end
    ops
  end

  def self.op(code, title, evidence, weights)
    { 'code' => code, 'title' => title, 'evidence' => evidence, 'weights' => weights }
  end

  def self.fmt_date(iso)
    iso.to_s[0, 10]
  end

  STOP = %w[para como con sin que los las del una uno unos unas por mas muy sus que este esta empresa empresas negocio negocios
            cliente clientes tipo ideal sector tengan tenga sean busco quiero].freeze

  def self.score(c, analysis, ops, ctx)
    offer = ctx['offer'].to_s
    types = offer_types(offer)
    year = Time.now.year
    haystack = Sectors.normalize([c[:name], c[:sector], (c[:sector_tags] || {}).values.join(' '),
                                  analysis && analysis['title'], analysis && analysis['description']].compact.join(' '))
    reasons = []

    # 1. Encaje con el cliente ideal (0-30)
    fit = 15
    reasons << 'Coincide con el sector buscado'
    words = Sectors.normalize("#{ctx['ideal']} #{ctx['customer_type']}").split(/[^a-z0-9]+/).select { |w| w.length >= 4 && !STOP.include?(w) }.uniq
    hits = words.select { |w| haystack.include?(w[0, [w.length, 6].min]) }
    if hits.any?
      fit += [hits.size * 5, 10].min
      reasons << "Rasgos del cliente ideal presentes (#{hits.first(3).join(', ')})"
    end
    relevant = ops.select { |o| types.any? { |t| (o['weights'][t] || 0) >= 8 } }
    if relevant.any?
      fit += 5
    end

    # 2. Necesidad aparente según lo que vendes (0-30)
    need = [ops.map { |o| types.map { |t| o['weights'][t] || 0 }.max }.sum, 30].min
    reasons << "Necesidad visible: #{relevant.map { |o| o['title'].downcase }.first(3).join('; ')}" if relevant.any?

    # 3. Margen de mejora digital (0-15)
    improvement = [ops.size * 3, 15].min

    # 4. Datos de contacto profesionales disponibles (0-15)
    contact = 0
    contact += 5 unless c[:phone].to_s.empty?
    contact += 6 unless c[:email].to_s.empty?
    contact += 4 unless c[:website].to_s.empty? && c[:instagram].to_s.empty?
    reasons << (contact >= 11 ? 'Buenos datos de contacto públicos' : contact.zero? ? 'Casi sin datos de contacto públicos' : 'Algunos datos de contacto públicos')

    # 5. Señales de actividad (0-10)
    activity = 0
    activity += 3 if c[:business_status] == 'OPERATIONAL' || c[:osm_ref]
    activity += 2 unless c[:opening_hours].to_s.empty?
    activity += 3 if analysis && analysis['copyright_year'].to_i >= year - 1
    activity += 2 if c[:rating_count].to_i >= 10
    reasons << 'Señales de actividad reciente' if activity >= 6

    total = [fit + need + improvement + contact + activity, 100].min
    tier = TIERS.find { |min, _| total >= min }[1]
    {
      score: total, tier: tier,
      breakdown: { 'Encaje con cliente ideal' => [fit, 30], 'Necesidad aparente' => [need, 30], 'Margen de mejora' => [improvement, 15],
                   'Datos de contacto' => [contact, 15], 'Señales de actividad' => [activity, 10] },
      explanation: "#{tier} (#{total}/100). " + reasons.join('. ') + '.'
    }
  end

  # Confianza global de los datos: alta / media / baja.
  def self.confidence(c, analysis)
    sources = (c[:found_in] || []).size
    web_ok = analysis && analysis['reachable']
    name_on_web = web_ok && Sectors.normalize(analysis['title'].to_s + ' ' + analysis['description'].to_s)
                            .include?(Sectors.normalize(c[:name]).split.max_by(&:length).to_s)
    if (web_ok && name_on_web) || sources >= 2
      'Alta'
    elsif web_ok || (!c[:address].to_s.empty? && !(c[:phone].to_s.empty? && c[:website].to_s.empty?))
      'Media'
    else
      'Baja'
    end
  end
end
