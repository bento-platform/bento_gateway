# Bento Gateway

OpenResty-based gateway, configuration, &amp; continuous building for inclusion in Bento deployments. 

Service-specific `location` blocks are not baked into the image. Instead, they can be mounted as a volume
at image start time; they will then be processed via `envsubst` and included by OpenResty.

## Client IP handling

The gateway resolves the real client IP for access logs, the `X-Real-IP` header, and per-IP rate limits:

* **TLS mode:** the `stream` server on `:443` passes connections to `127.0.0.1:444` with a PROXY protocol header,
  which the `http` block trusts only from `127.0.0.1`. Keycloak traffic goes through a local relay on
  `127.0.0.1:445` that strips the header, so Keycloak does not need PROXY protocol support.
* **No-TLS mode:** set `BENTO_GATEWAY_TRUSTED_PROXY_CIDRS` to the CIDR(s) of the load balancer that terminates TLS;
  its `X-Forwarded-For` header is then trusted.

Requests that `bento_public` makes on behalf of a browser use the last `X-Forwarded-For` entry as the client IP.
Set `BENTO_GATEWAY_BFF_CIDRS` to the subnet(s) of the network that `bento_public` uses to reach the gateway. These
requests also skip the `perip`/`perserver` rate limits, since the browser's request to `bento_public` was already
counted.

Both variables take comma- or space-separated CIDR lists.
