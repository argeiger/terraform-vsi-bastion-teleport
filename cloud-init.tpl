#cloud-config
packages:
  - tar
write_files:
  - path: /root/license.pem
    permissions: '0644'
    encoding: base64
    content: ${TELEPORT_LICENSE}

  - path: /root/cert.pem
    permission: '0644'
    encoding: base64
    content: ${HTTPS_CERT}
    
  - path: /root/key.pem
    permission: '0644'
    encoding: base64
    content: ${HTTPS_KEY}

  - path: /root/roles.yaml
    permission: '0644'
    content: |
      # Example role
      # Add any additional ones to the end
      kind: "role"
      version: "v3"
      metadata:
        name: "teleport-admin"
      spec:
        options:
          max_connections: 3
          cert_format: standard
          client_idle_timeout: 15m
          disconnect_expired_cert: no
          enhanced_recording:
          - command
          - network
          forward_agent: true
          max_session_ttl: 1h
          port_forwarding: false
        allow:
          logins: [root]
          node_labels:
            "*": "*"
          rules:
          - resources: ["*"]
            verbs: ["*"]
      ---
   
  - path: /root/oidc.yaml
    permission: '0644'
    content: |
      #oidc connector
      kind: oidc
      version: v2
      metadata:
        name: appid
      spec:
        redirect_url: "https://${HOSTNAME}.${DOMAIN}:3080/v1/webapi/oidc/callback"
        client_id: "${APPID_CLIENT_ID}"
        display: AppID
        client_secret: "${APPID_CLIENT_SECRET}"
        issuer_url: "${APPID_ISSUER_URL}"
        scope: ["openid", "email"]
        claims_to_roles: 
         %{~ for claims in CLAIM_TO_ROLES ~}
          - {claim: "email", value: "${claims.email}", roles: ${jsonencode(claims.roles)}}
         %{~ endfor ~}

  - path: /etc/teleport.yaml
    permission: '0644'
    content: |
      #teleport.yaml
      teleport:
        nodename: ${HOSTNAME}.${DOMAIN}
        data_dir: /var/lib/teleport
        log:
          output: stderr
          severity: DEBUG 
        storage:
          audit_sessions_uri: "s3://${COS_BUCKET}?endpoint=${COS_BUCKET_ENDPOINT}&region=ibm"

      auth_service:
        enabled: "yes"
        listen_addr: 0.0.0.0:3025
        authentication:
          type: oidc
          local_auth: false
        license_file: /var/lib/teleport/license.pem
        message_of_the_day: ${MESSAGE_OF_THE_DAY}

      ssh_service:
        enabled: "yes"
        commands:
        - name: hostname
          command: [hostname]
          period: 1m0s
        - name: arch
          command: [uname, -p]
          period: 1h0m0s

      proxy_service:
        enabled: "yes"
        listen_addr: 0.0.0.0:3023
        web_listen_addr: 0.0.0.0:3080
        tunnel_listen_addr: 0.0.0.0:3024
        https_cert_file: /var/lib/teleport/cert.pem
        https_key_file: /var/lib/teleport/key.pem

  - path: /etc/systemd/system/teleport.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Teleport Service
      After=network.target

      [Service]
      Type=simple
      Restart=on-failure
      Environment=AWS_ACCESS_KEY_ID="${HMAC_ACCESS_KEY_ID}"
      Environment=AWS_SECRET_ACCESS_KEY="${HMAC_SECRET_ACCESS_KEY_ID}"
      ExecStart=/usr/local/bin/teleport start --config=/etc/teleport.yaml --pid-file=/run/teleport.pid
      ExecReload=/bin/kill -HUP $MAINPID
      PIDFile=/run/teleport.pid

      [Install]
      WantedBy=multi-user.target

  - path: /root/install.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -x
      setup_path="/root"
      teleport_file="teleport-ent-v${TELEPORT_VERSION}-linux-amd64-bin.tar.gz"
      teleport_url="https://get.gravitational.com/$teleport_file"

      #retrieve and extract teleport
      cd $setup_path
      curl --connect-timeout 30 --retry 15 --retry-delay 10 $teleport_url --output $teleport_file
      tar -xvzf $teleport_file

      #Copy files over
      cp $setup_path/teleport-ent/teleport /usr/local/bin/
      cp $setup_path/teleport-ent/tctl /usr/local/bin/
      cp $setup_path/teleport-ent/tsh /usr/local/bin/

      #Make the /var/lib/teleport directory
      TELEPORT_CONFIG_PATH="/var/lib/teleport"
      mkdir $TELEPORT_CONFIG_PATH

      #copy files for /root to /var/lib/
      cp $setup_path/license.pem $TELEPORT_CONFIG_PATH
      cp $setup_path/cert.pem $TELEPORT_CONFIG_PATH
      cp $setup_path/key.pem $TELEPORT_CONFIG_PATH

      sudo systemctl daemon-reload
      sudo systemctl start teleport
      sudo systemctl enable teleport

      # allow ports for firewall 
      # check if firewalld is used
      firewall-cmd -h 
      rc=$?
      if [[ $rc -eq 0 ]]; then
         systemctl stop firewalld
         sudo firewall-offline-cmd --zone=public --add-port=3023/tcp
         #sudo firewall-cmd --permanent --zone=public --add-port=3023/tcp
         sudo firewall-offline-cmd --zone=public --add-port=3080/tcp
         #sudo firewall-cmd --permanent --zone=public --add-port=3080/tcp
         systemctl start firewalld
      fi

      # check if firewalld is used
      ufw version
      rc=$?
      if [[ $rc -eq 0 ]]; then
         ufw allow 3023,3080/tcp
      fi

      #distro=$(awk '/DISTRIB_ID=/' /etc/*-release | sed 's/DISTRIB_ID=//' | tr '[:upper:]' '[:lower:]')
      #echo $distro
      #if [[ $distro == "ubuntu" ]]; then
      #    ufw allow 3023,3080/tcp
      #fi

runcmd:
   - /root/install.sh