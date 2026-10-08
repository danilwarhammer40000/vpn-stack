# Managed by vpn-stack. Port 80 serves three things:
#   1. Let's Encrypt HTTP-01 challenges for the TrustTunnel domain (certbot --webroot)
#   2. the Xray XHTTP path, proxied to the local Xray inbound (reached through the CDN)
#   3. 404 for everything else
server {
    listen 80 default_server;
    server_name _;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type text/plain;
    }

    location @XRAY_PATH@ {
        proxy_pass http://127.0.0.1:@XRAY_PORT@;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
        client_body_timeout 1h;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }

    location / {
        return 404;
    }
}
