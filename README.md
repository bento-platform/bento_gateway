# bento_gateway

OpenResty-based gateway, configuration, &amp; continuous building for inclusion in Bento deployments. 

Service-specific `location` blocks are not baked into the image. Instead, they can be mounted as a volume
at image start time; they will then be processed via `envsubst` and included by OpenResty.
