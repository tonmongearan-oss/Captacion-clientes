# Carga variables desde el archivo .env (formato CLAVE=valor) sin dependencias externas.
module Env
  ROOT = File.expand_path('..', __dir__)

  def self.load!
    path = File.join(ROOT, '.env')
    return unless File.exist?(path)
    File.readlines(path, encoding: 'UTF-8').each do |line|
      line = line.strip
      next if line.empty? || line.start_with?('#')
      key, value = line.split('=', 2)
      next unless key && value
      value = value.strip
      value = value[1..-2] if value.length >= 2 && ((value.start_with?('"') && value.end_with?('"')) || (value.start_with?("'") && value.end_with?("'")))
      ENV[key.strip] = value unless ENV.key?(key.strip) # las variables reales (p. ej. en Render) mandan
    end
  end

  def self.get(key, default = nil)
    v = ENV[key]
    v.nil? || v.strip.empty? ? default : v.strip
  end

  def self.int(key, default)
    Integer(get(key, default.to_s)) rescue default
  end
end
