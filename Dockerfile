FROM openresty/openresty:1.27.1.1-0-alpine-fat

# Install apt and lua dependencies
RUN apk add --no-cache git bash python3 && \
    /usr/local/openresty/luajit/bin/luarocks install lua-resty-http && \
    /usr/local/openresty/luajit/bin/luarocks install lua-resty-jwt

WORKDIR /gateway
RUN mkdir -p /usr/local/openresty/nginx/conf/bento_services && \
    mkdir -p /usr/local/openresty/nginx/conf/bento_public_services && \
    mkdir -p /gateway/services && \
    mkdir -p /gateway/public_services
COPY conf conf
COPY src src
COPY entrypoint.bash .
COPY LICENSE .

ENTRYPOINT ["bash", "./entrypoint.bash"]
