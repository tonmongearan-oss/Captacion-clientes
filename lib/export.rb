require 'zlib'

# Exportación a CSV (compatible con Excel en español) y XLSX (escritor OOXML propio, sin dependencias).
module Export
  NF = 'No encontrado'.freeze
  COLUMNS = [
    ['Empresa', 'name'], ['Sector', 'sector'], ['Dirección', 'address'], ['Código postal', 'postcode'], ['Ciudad', 'city'],
    ['Provincia', 'province'], ['Comunidad autónoma', 'region'], ['País', 'country'], ['Web', 'website'], ['Instagram', 'instagram'],
    ['Facebook', 'facebook'], ['LinkedIn', 'linkedin'], ['TikTok', 'tiktok'], ['Teléfono', 'phone'], ['Email', 'email'], ['WhatsApp', 'whatsapp'],
    ['Decisor', 'decision_maker'], ['Fuente decisor', 'decision_maker_source'], ['Empleados', 'employees'], ['Valoración Google', 'rating'],
    ['Nº reseñas', 'rating_count'], ['Puntuación', 'score'], ['Prioridad', 'score_tier'], ['Explicación puntuación', 'score_explanation'],
    ['Oportunidades', :opportunities], ['Confianza', 'confidence'], ['Estado comercial', 'status'], ['Próxima acción', 'next_action'],
    ['Fecha próxima acción', 'next_action_date'], ['Último contacto', 'last_contact_date'], ['Notas', :notes],
    ['Fuentes por campo', :sources], ['Origen del dato', 'source_note'], ['Base jurídica', 'lawful_basis'],
    ['Última comprobación', 'last_checked_at'], ['Guardado en base', :saved]
  ].freeze

  def self.rows(companies)
    companies.map do |c|
      COLUMNS.map do |_, key|
        case key
        when :opportunities then (c['opportunities'] || []).map { |o| o['title'] }.join('; ').then { |s| s.empty? ? 'Ninguna detectada' : s }
        when :notes then DB.all("SELECT text, created_at FROM crm_events WHERE company_id = ? AND kind = 'nota' ORDER BY created_at", [c['id']])
                           .map { |e| "[#{e['created_at'][0, 10]}] #{e['text']}" }.join(' | ')
        when :sources then (c['field_sources'] || {}).map { |f, s| "#{f}: #{s['source']} (#{s['url']})" }.join(' | ')
        when :saved then c['saved'].to_i == 1 ? 'Sí' : 'No'
        else
          v = c[key]
          v.nil? || v.to_s.strip.empty? ? (%w[next_action next_action_date last_contact_date decision_maker_source].include?(key) ? '' : NF) : v
        end
      end
    end
  end

  def self.csv(companies)
    esc = ->(v) { s = v.to_s; s =~ /[;"\n\r]/ ? "\"#{s.gsub('"', '""')}\"" : s }
    lines = [COLUMNS.map(&:first).map(&esc).join(';')]
    rows(companies).each { |r| lines << r.map(&esc).join(';') }
    "﻿" + lines.join("\r\n") + "\r\n" # BOM + punto y coma: Excel en español lo abre bien
  end

  def self.xml(s)
    s.to_s.gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/, '').gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
  end

  def self.col_name(i)
    name = ''
    i += 1
    while i > 0
      i, r = (i - 1).divmod(26)
      name = (65 + r).chr + name
    end
    name
  end

  def self.xlsx(companies)
    data = [COLUMNS.map(&:first)] + rows(companies)
    sheet = +'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    sheet << '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
    sheet << '<cols>' + COLUMNS.each_with_index.map { |(h, _), i| "<col min=\"#{i + 1}\" max=\"#{i + 1}\" width=\"#{[[h.length + 4, 14].max, 40].min}\" customWidth=\"1\"/>" }.join + '</cols><sheetData>'
    data.each_with_index do |row, ri|
      sheet << "<row r=\"#{ri + 1}\">"
      row.each_with_index do |v, ci|
        ref = "#{col_name(ci)}#{ri + 1}"
        style = ri.zero? ? ' s="1"' : ''
        if v.is_a?(Numeric)
          sheet << "<c r=\"#{ref}\"#{style}><v>#{v}</v></c>"
        else
          sheet << "<c r=\"#{ref}\" t=\"inlineStr\"#{style}><is><t xml:space=\"preserve\">#{xml(v.to_s[0, 32_000])}</t></is></c>"
        end
      end
      sheet << '</row>'
    end
    sheet << "</sheetData><autoFilter ref=\"A1:#{col_name(COLUMNS.size - 1)}#{data.size}\"/></worksheet>"

    files = {
      '[Content_Types].xml' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>',
      '_rels/.rels' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
      'xl/workbook.xml' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Leads" sheetId="1" r:id="rId1"/></sheets><definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">Leads!$A$1:$' + col_name(COLUMNS.size - 1) + '$' + data.size.to_s + '</definedName></definedNames></workbook>',
      'xl/_rels/workbook.xml.rels' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
      'xl/styles.xml' => '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFE8EEF9"/></patternFill></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="2"><xf/><xf fontId="1" fillId="2" applyFont="1" applyFill="1"/></cellXfs></styleSheet>',
      'xl/worksheets/sheet1.xml' => sheet
    }
    zip(files)
  end

  # Escritor ZIP mínimo (deflate) suficiente para un .xlsx.
  def self.zip(files)
    out = ''.b
    central = ''.b
    files.each do |name, content|
      raw = content.dup.force_encoding('BINARY')
      crc = Zlib.crc32(raw)
      z = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
      comp = z.deflate(raw, Zlib::FINISH)
      z.close
      offset = out.bytesize
      nameb = name.b
      out << [0x04034b50, 20, 0x0800, 8, 0, 0x21, crc, comp.bytesize, raw.bytesize, nameb.bytesize, 0].pack('VvvvvvVVVvv') << nameb << comp
      central << [0x02014b50, 20, 20, 0x0800, 8, 0, 0x21, crc, comp.bytesize, raw.bytesize, nameb.bytesize, 0, 0, 0, 0, 0, offset].pack('VvvvvvvVVVvvvvvVV') << nameb
    end
    central_offset = out.bytesize
    out << central << [0x06054b50, 0, 0, files.size, files.size, central.bytesize, central_offset, 0].pack('VvvvvVVv')
    out
  end
end
