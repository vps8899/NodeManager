import json
import uuid

# Base config
config = {
  "log": {
    "disabled": False,
    "level": "info",
    "output": "/etc/node-manager/logs/sing-box.log",
    "timestamp": True
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "protocol": "dns",
        "outbound": "direct"
      }
    ]
  }
}

# VLESS Reality
vless_inbound = {
  "type": "vless",
  "tag": "vless-in-443",
  "listen": "::",
  "listen_port": 443,
  "sniff": True,
  "sniff_override_destination": True,
  "users": [
    {
      "uuid": str(uuid.uuid4()),
      "flow": "xtls-rprx-vision"
    }
  ],
  "tls": {
    "enabled": True,
    "server_name": "yahoo.com",
    "reality": {
      "enabled": True,
      "handshake": {
        "server": "yahoo.com",
        "server_port": 443
      },
      "private_key": "CINrE2LQ0Jlo_b29553Op5diutGNWwQkz6UTGHeYvGU",
      "short_id": ["12345678"]
    }
  }
}
config["inbounds"].append(vless_inbound)

# Hysteria2
hy2_inbound = {
  "type": "hysteria2",
  "tag": "hy2-in-443",
  "listen": "::",
  "listen_port": 443,
  "users": [
    {
      "password": "somepassword"
    }
  ],
  "tls": {
    "enabled": True,
    "certificate_path": "cert.pem",
    "key_path": "key.pem"
  }
}
config["inbounds"].append(hy2_inbound)

# TUIC
tuic_inbound = {
  "type": "tuic",
  "tag": "tuic-in-8443",
  "listen": "::",
  "listen_port": 8443,
  "users": [
    {
      "uuid": str(uuid.uuid4()),
      "password": "somepassword"
    }
  ],
  "tls": {
    "enabled": True,
    "certificate_path": "cert.pem",
    "key_path": "key.pem"
  }
}
config["inbounds"].append(tuic_inbound)

# Argo
argo_inbound = {
  "type": "vless",
  "tag": "vless-argo-8080",
  "listen": "127.0.0.1",
  "listen_port": 8080,
  "users": [
    {
      "uuid": str(uuid.uuid4())
    }
  ],
  "transport": {
    "type": "ws",
    "path": "/somepath"
  }
}
config["inbounds"].append(argo_inbound)

with open("D:\\博客内容\\代码\\一键搭建脚本\\NodeManager\\config.json", "w") as f:
    json.dump(config, f, indent=2)

print("Generated config.json")
