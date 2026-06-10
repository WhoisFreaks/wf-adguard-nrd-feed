
FROM alpine:3.19
 
RUN apk add --no-cache \
    bash \
    curl \
    python3 \
    py3-yaml \
    gzip \
    ca-certificates
 
WORKDIR /app
 
COPY fetch-nrd.sh /app/fetch-nrd.sh
COPY entrypoint.sh /app/entrypoint.sh
 
RUN chmod +x /app/fetch-nrd.sh /app/entrypoint.sh && \
    mkdir -p /app/output /app/cache
 
ENTRYPOINT ["/app/entrypoint.sh"]
