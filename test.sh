proxy_names="\n      - \"VLESS-Reality\""
cat > clash.yaml <<EOF
proxy-groups:
  - name: PROXY
    type: select
    proxies:$(echo -e "$proxy_names")
EOF
cat clash.yaml