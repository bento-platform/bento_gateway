FROM openresty/openresty:1.21.4.1-0-bullseye

WORKDIR /gateway
RUN mkdir -p /usr/local/openresty/nginx/conf/bento_services && \
    mkdir -p /gateway/services
COPY LICENSE LICENSE
COPY conf conf
COPY src src
COPY entrypoint.bash entrypoint.bash
COPY VARIABLES VARIABLES

ENTRYPOINT ["bash", "./entrypoint.bash"]
