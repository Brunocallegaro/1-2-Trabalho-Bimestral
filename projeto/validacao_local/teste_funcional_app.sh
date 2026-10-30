#!/bin/bash
echo "# Teste funcional do app.py fora do Kubernetes ($(date -Iseconds))"
echo "# Python local: $(python3 --version) | CPUs da VM: $(nproc)"
echo "# Processo A: sem limite de CPU (porta 8001). Processo B: cgroup com quota de 50 ms a cada 100 ms = 500m (porta 8000)."
echo; echo "\$ curl /healthz";  curl -s localhost:8000/healthz; echo
echo "\$ curl /readyz";  curl -s localhost:8000/readyz; echo
echo "\$ curl / (status e tipo)"; curl -s -o /dev/null -w "%{http_code} %{content_type}\n" localhost:8000/
echo "\$ curl /api/rota?paradas=2"; curl -s -w " HTTP %{http_code}\n" "localhost:8000/api/rota?paradas=2"
echo "\$ curl /inexistente"; curl -s -w " HTTP %{http_code}\n" localhost:8000/inexistente
echo; echo "## 10 calculos com paradas=9 SEM limite de CPU (calculo_ms)"
for i in $(seq 10); do curl -s "localhost:8001/api/rota?paradas=9" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['calculo_ms'],'ms  distancia=',d['distancia'],' ordem=',d['ordem'])"; done
echo; echo "## 10 calculos com paradas=9 COM limite de 500m (calculo_ms)"
for i in $(seq 10); do curl -s "localhost:8000/api/rota?paradas=9" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['calculo_ms'],'ms')"; done
echo; echo "## Dois pedidos simultaneos no processo limitado (espera-se um 200 e um 503)"
curl -s -o /dev/null -w "pedido 1: HTTP %{http_code}\n" "localhost:8000/api/rota?paradas=9" & sleep 0.05
curl -s -w "  <- pedido 2: HTTP %{http_code}\n" "localhost:8000/api/rota?paradas=9"; wait
