server {
	listen 80 default_server;
	listen [::]:80 default_server;

	server_name _;

	root /var/www/html/openems;

	index	index.html;

	# Re-resolve upstream container IPs at request time via Docker's embedded DNS
	# (127.0.0.11). Without this, nginx resolves the backend hostname once at boot
	# and caches the IP -- so a recreated backend (new IP) yields 502 / "Server
	# not accessible" until nginx is restarted. Using a variable in proxy_pass
	# forces per-request resolution against the resolver below.
	resolver 127.0.0.11 valid=10s ipv6=off;

	# OpenEMS Web-Interface
	location / {
		try_files $uri $uri/ /index.html;
		error_page	404 300 /index.html;
	}

	# OpenEMS Backend Proxy (websocket)
	location /openems-backend {
		set $oems_backend "$WEBSOCKET_HOST:$WEBSOCKET_PORT";
		proxy_pass http://$oems_backend;
		proxy_http_version 1.1;
		proxy_set_header Upgrade $http_upgrade;
		proxy_set_header Connection 'upgrade';
		proxy_set_header Host $host;
		proxy_cache_bypass $http_upgrade;
	}

	location /rest {
		set $oems_rest "$WEBSOCKET_HOST:$REST_PORT";
		proxy_pass http://$oems_rest;
		proxy_set_header Host $host;
		proxy_set_header X-Real-IP $remote_addr;
		proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto http;
	}
}
