# Imagen para publicar la app en internet (Render u otro servicio con Docker).
FROM ruby:3.3-slim

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    BIND_ADDRESS=0.0.0.0 \
    DATA_DIR=/var/data \
    PORT=10000

WORKDIR /app
COPY Gemfile ./
RUN bundle install --jobs 4

COPY server.rb ./
COPY lib ./lib
COPY public ./public

# La base de datos vive en el disco persistente montado en /var/data.
RUN mkdir -p /var/data
EXPOSE 10000
CMD ["bundle", "exec", "ruby", "server.rb"]
