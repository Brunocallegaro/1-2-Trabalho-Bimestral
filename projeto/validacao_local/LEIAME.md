# Validação local (fora do Kubernetes)

**Estes arquivos NÃO são as medições da atividade.** Eles foram gerados durante a
preparação do projeto, em uma VM Linux na nuvem com 2 vCPUs, **sem Kubernetes**,
porque esse ambiente não tinha acesso ao Docker Hub (não foi possível baixar
`python:3.12-slim`, `grafana/k6:1.0.0` nem a imagem do nó do Minikube).

Servem só para mostrar que a aplicação e o script de carga funcionam e para dar
uma ideia de ordem de grandeza na calibração. **Não entram em `resultados.csv`,
nem na tabela 1/2/3 Pods.**

| Arquivo | O que é |
|---|---|
| `teste_funcional_app.sh` | Script usado no teste funcional (curl nos endpoints). |
| `teste_funcional_app.txt` | Saída real: `/healthz`, `/readyz`, `/`, erros 400 e 404, 10 cálculos sem limite de CPU, 10 cálculos com limite de 500m (cgroup), e o 503 quando chegam dois pedidos juntos. |
| `k6_local_1processo_taxa6.txt` | Saída real do `carga.js` (k6 v1.0.0) contra **um processo** do `app.py` limitado a 500m, `TAXA=6`, `PARADAS=9`, `DURACAO=60`. |

## O que esses dados mostram

- Com `paradas=9`, um cálculo levou **218–326 ms** sem limite de CPU e **418–586 ms**
  com limite de 500m (mediana ≈ 473 ms). Isso bate com a estimativa do guia (≈ 0,45 s
  por cálculo com meia CPU), ou seja, cerca de **2 pedidos por segundo por réplica**.
- No k6 local (1 processo, taxa 6/s): `rotas_ok=105` (1,75 sucesso/s), `falhas=70,91%`
  (256 de 361), `latencia_ok p(95)=650,11 ms`, `dropped_iterations{scenario:medicao}=0`.
  O k6 saiu com código **99** (meta de falhas não atingida), exatamente o comportamento
  que o guia descreve para o Job `Failed` com 1 Pod.

## Por que não vale como medição da atividade

Não há Service, kube-proxy, Pods, metrics-server nem o nó de 3 CPUs do Minikube; o
gerador e a aplicação disputaram as mesmas 2 vCPUs. A comparação 1/2/3 Pods precisa
ser feita no cluster, com o roteiro do guia (`scripts/ciclo-medicao.ps1`).
