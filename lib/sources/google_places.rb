# Integración opcional con Google Places API (New) - Text Search.
# Requiere GOOGLE_PLACES_API_KEY en .env. Tiene coste por petición (ver README).
module GooglePlaces
  URL = 'https://places.googleapis.com/v1/places:searchText'.freeze
  FIELDS = %w[places.id places.displayName places.formattedAddress places.addressComponents places.location
              places.nationalPhoneNumber places.internationalPhoneNumber places.websiteUri places.businessStatus
              places.primaryTypeDisplayName places.googleMapsUri places.rating places.userRatingCount nextPageToken].join(',')

  def self.enabled?
    !Env.get('GOOGLE_PLACES_API_KEY').nil?
  end

  def self.search(text_query, limit)
    out = []
    token = nil
    3.times do
      body = { textQuery: text_query, languageCode: 'es', regionCode: 'ES', pageSize: 20 }
      body[:pageToken] = token if token
      r = HttpClient.request(:post, URL, body: JSON.generate(body), timeout: 30, headers: {
                               'Content-Type' => 'application/json',
                               'X-Goog-Api-Key' => Env.get('GOOGLE_PLACES_API_KEY'),
                               'X-Goog-FieldMask' => FIELDS
                             })
      unless r.code == 200
        msg = (JSON.parse(r.body)['error']['message'] rescue "HTTP #{r.code}")
        raise HttpClient::Error, "Google Places: #{msg}"
      end
      data = JSON.parse(r.body)
      (data['places'] || []).each { |p| c = to_company(p); out << c if c }
      token = data['nextPageToken']
      break if token.nil? || out.size >= limit
      sleep 2 # el token de página tarda unos segundos en activarse
    end
    out
  end

  def self.component(p, type)
    comp = (p['addressComponents'] || []).find { |c| (c['types'] || []).include?(type) }
    comp && comp['longText']
  end

  def self.to_company(p)
    return nil if p['businessStatus'] == 'CLOSED_PERMANENTLY'
    name = p.dig('displayName', 'text')
    return nil if name.to_s.empty?
    src = p['googleMapsUri'] || 'https://maps.google.com'
    route = component(p, 'route')
    number = component(p, 'street_number')
    c = {
      name: name,
      sector: p.dig('primaryTypeDisplayName', 'text'),
      address: route ? [route, number].compact.join(', ') : p['formattedAddress'],
      postcode: component(p, 'postal_code'),
      city: component(p, 'locality'),
      province: component(p, 'administrative_area_level_2'),
      region: component(p, 'administrative_area_level_1'),
      country: component(p, 'country'),
      lat: p.dig('location', 'latitude'), lon: p.dig('location', 'longitude'),
      website: p['websiteUri'],
      phone: p['nationalPhoneNumber'] || p['internationalPhoneNumber'],
      google_place_id: p['id'], maps_url: p['googleMapsUri'],
      rating: p['rating'], rating_count: p['userRatingCount'], business_status: p['businessStatus'],
      field_sources: {}
    }
    %i[name sector address postcode city province region country website phone rating business_status].each do |f|
      c[:field_sources][f.to_s] = { 'source' => 'Google Places', 'url' => src } unless c[f].nil?
    end
    c
  end
end
