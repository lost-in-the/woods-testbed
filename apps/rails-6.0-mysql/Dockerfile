FROM ruby:3.0-slim

ENV LANG=C.UTF-8 \
    BUNDLE_PATH=/bundle \
    BUNDLE_BIN=/bundle/bin \
    BUNDLE_APP_CONFIG=/bundle/.bundle \
    BUNDLE_WITHOUT="production" \
    PATH=/bundle/bin:/app/bin:$PATH

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      build-essential \
      git \
      default-libmysqlclient-dev \
      libyaml-dev \
      pkg-config \
      curl \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Optional: trust an intercepting egress CA. bin/ccr_compose.sh stages a real
# bundle here when the session sits behind one; on a laptop the file is empty
# and this layer is a no-op. Must run before any gem/apt fetch over HTTPS.
COPY ca-bundle.crt /usr/local/share/ca-certificates/ccr-agent-proxy.crt
RUN if [ -s /usr/local/share/ca-certificates/ccr-agent-proxy.crt ]; then \
      update-ca-certificates; \
    else \
      rm -f /usr/local/share/ca-certificates/ccr-agent-proxy.crt; \
    fi

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    BUNDLE_SSL_CA_CERT=/etc/ssl/certs/ca-certificates.crt

RUN gem install bundler -v 2.4.22 --no-document

WORKDIR /app

EXPOSE 3000

CMD ["bash", "-lc", "bundle install --jobs 4 && bin/rails db:prepare && bin/rails server -b 0.0.0.0 -p 3000"]
