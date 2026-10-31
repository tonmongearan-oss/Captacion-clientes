# Traducción de sectores escritos en español a etiquetas de OpenStreetMap.
# Cada entrada: palabras clave (sin acentos, en minúsculas) => [nombre legible, [selectores Overpass]].
module Sectors
  MAP = [
    [%w[dental dentista dentistas odontolog clinica\ dental clinicas\ dentales ortodonc], 'Clínica dental',
     ['["amenity"="dentist"]', '["healthcare"="dentist"]']],
    [%w[fisioterap fisio], 'Fisioterapia', ['["healthcare"="physiotherapist"]']],
    [%w[psicolog], 'Psicología', ['["healthcare"="psychotherapist"]', '["healthcare:speciality"="psychiatry"]']],
    [%w[veterinari], 'Veterinaria', ['["amenity"="veterinary"]']],
    [%w[clinica clinicas medico medicos centro\ medico], 'Clínica / centro médico',
     ['["amenity"="clinic"]', '["healthcare"="clinic"]', '["amenity"="doctors"]', '["healthcare"="doctor"]']],
    [%w[farmacia], 'Farmacia', ['["amenity"="pharmacy"]']],
    [%w[optica opticas], 'Óptica', ['["shop"="optician"]']],
    [%w[peluquer barberia barber], 'Peluquería / barbería', ['["shop"="hairdresser"]']],
    [%w[estetica belleza unas manicura spa], 'Centro de estética', ['["shop"="beauty"]', '["leisure"="spa"]']],
    [%w[tatuaje tattoo], 'Estudio de tatuajes', ['["shop"="tattoo"]']],
    [%w[gimnasio gimnasios gym fitness crossfit], 'Gimnasio', ['["leisure"="fitness_centre"]', '["leisure"="sports_centre"]']],
    [%w[yoga pilates], 'Yoga / pilates', ['["sport"="yoga"]', '["leisure"="fitness_centre"]["sport"~"yoga|pilates"]']],
    [%w[restaurante restaurantes], 'Restaurante', ['["amenity"="restaurant"]']],
    [%w[bar bares cerveceria], 'Bar', ['["amenity"="bar"]', '["amenity"="pub"]']],
    [%w[cafeteria cafeterias cafe], 'Cafetería', ['["amenity"="cafe"]']],
    [%w[panaderia pasteleria], 'Panadería / pastelería', ['["shop"="bakery"]', '["shop"="pastry"]']],
    [%w[hotel hoteles hostal alojamiento], 'Hotel / alojamiento', ['["tourism"="hotel"]', '["tourism"="guest_house"]', '["tourism"="hostel"]']],
    [%w[apartamento turistic], 'Apartamentos turísticos', ['["tourism"="apartment"]']],
    [%w[inmobiliaria inmobiliarias], 'Inmobiliaria', ['["office"="estate_agent"]', '["shop"="estate_agent"]']],
    [%w[abogado abogados bufete despacho\ de\ abogados], 'Abogados', ['["office"="lawyer"]']],
    [%w[asesoria gestoria contable contabilidad fiscal], 'Asesoría / gestoría',
     ['["office"="accountant"]', '["office"="tax_advisor"]', '["office"="consulting"]']],
    [%w[notari], 'Notaría', ['["office"="notary"]']],
    [%w[arquitect], 'Arquitectura', ['["office"="architect"]']],
    [%w[seguros aseguradora], 'Seguros', ['["office"="insurance"]']],
    [%w[agencia\ de\ viajes viajes], 'Agencia de viajes', ['["shop"="travel_agency"]']],
    [%w[autoescuela], 'Autoescuela', ['["amenity"="driving_school"]']],
    [%w[academia academias formacion idiomas], 'Academia / formación', ['["amenity"="language_school"]', '["amenity"="training"]', '["office"="educational_institution"]']],
    [%w[guarderia escuela\ infantil], 'Escuela infantil', ['["amenity"="kindergarten"]']],
    [%w[taller mecanico talleres], 'Taller mecánico', ['["shop"="car_repair"]']],
    [%w[concesionario coches automovil], 'Concesionario', ['["shop"="car"]']],
    [%w[floristeria floristerias flores], 'Floristería', ['["shop"="florist"]']],
    [%w[ropa moda boutique], 'Tienda de ropa', ['["shop"="clothes"]', '["shop"="boutique"]']],
    [%w[zapateria], 'Zapatería', ['["shop"="shoes"]']],
    [%w[joyeria], 'Joyería', ['["shop"="jewelry"]']],
    [%w[muebles decoracion interiorismo], 'Muebles / decoración', ['["shop"="furniture"]', '["shop"="interior_decoration"]']],
    [%w[ferreteria], 'Ferretería', ['["shop"="hardware"]', '["shop"="doityourself"]']],
    [%w[libreria], 'Librería', ['["shop"="books"]']],
    [%w[mascotas], 'Tienda de mascotas', ['["shop"="pet"]']],
    [%w[supermercado alimentacion], 'Alimentación', ['["shop"="supermarket"]', '["shop"="convenience"]']],
    [%w[carniceria], 'Carnicería', ['["shop"="butcher"]']],
    [%w[fruteria], 'Frutería', ['["shop"="greengrocer"]']],
    [%w[vinoteca bodega vinos], 'Vinoteca', ['["shop"="wine"]']],
    [%w[electricista], 'Electricista', ['["craft"="electrician"]']],
    [%w[fontanero fontaneria], 'Fontanería', ['["craft"="plumber"]']],
    [%w[carpinter], 'Carpintería', ['["craft"="carpenter"]']],
    [%w[reformas construccion constructora], 'Reformas / construcción', ['["craft"="builder"]', '["office"="construction_company"]']],
    [%w[fotograf], 'Fotografía', ['["craft"="photographer"]', '["shop"="photo"]']],
    [%w[imprenta], 'Imprenta', ['["shop"="copyshop"]', '["craft"="printer"]']],
    [%w[lavanderia tintoreria], 'Lavandería / tintorería', ['["shop"="laundry"]', '["shop"="dry_cleaning"]']],
    [%w[coworking], 'Coworking', ['["amenity"="coworking_space"]', '["office"="coworking"]']],
    [%w[agencia\ de\ marketing marketing publicidad], 'Agencia de marketing', ['["office"="advertising_agency"]']],
    [%w[informatica tecnologia software], 'Informática / software', ['["office"="it"]', '["shop"="computer"]']],
    [%w[eventos catering], 'Eventos / catering', ['["craft"="caterer"]', '["amenity"="events_venue"]']]
  ].freeze

  def self.normalize(text)
    text.to_s.downcase.tr('áàäâéèëêíìïîóòöôúùüûñç', 'aaaaeeeeiiiioooouuuunc').gsub(/\s+/, ' ').strip
  end

  # Devuelve {label:, selectors:, matched:} o nil si el sector no está en el diccionario.
  def self.resolve(sector_text)
    norm = normalize(sector_text)
    return nil if norm.empty?
    best = nil
    MAP.each do |keywords, label, selectors|
      keywords.each do |kw|
        next unless norm =~ /(^|[\s\/,])#{Regexp.escape(kw)}/ # coincidencia al inicio de palabra
        best = [kw.length, label, selectors] if best.nil? || kw.length > best[0]
      end
    end
    best ? { label: best[1], selectors: best[2] } : nil
  end

  def self.labels
    MAP.map { |m| m[1] }
  end

  # Etiquetas OSM -> texto de sector legible para resultados.
  def self.label_from_tags(tags)
    MAP.each do |_, label, selectors|
      selectors.each do |sel|
        sel.scan(/\["([^"]+)"="([^"]+)"\]/).each do |k, v|
          return label if tags[k] == v
        end
      end
    end
    %w[shop office amenity craft healthcare tourism leisure].each do |k|
      return "#{k}: #{tags[k]}" if tags[k]
    end
    nil
  end
end
