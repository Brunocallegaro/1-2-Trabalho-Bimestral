# RotaExpress — Kubernetes na prática

Projeto de operações: publicar a aplicação RotaExpress no Kubernetes (Minikube), expor
com um Service, provocar uma falha de implantação e reverter, gerar carga controlada com
k6 dentro do cluster e comparar 1, 2 e 3 Pods.

O roteiro oficial é o **Guia_Atividade.pdf** do professor. Este README resume como
executar **este pacote** no Windows 10/11 (PowerShell). No Ubuntu os comandos `kubectl`,
`docker` e `minikube` são iguais; troque `curl.exe` por `curl`.

## Situação das evidências (leia antes de apresentar)

| Item | Situação |
|---|---|
| Manifestos `k8s/*.yaml` | Escritos conforme o guia e validados contra o schema do Kubernetes 1.33 (kubeconform: 5 válidos, 0 inválidos). |
| Aplicação e `carga.js` | Testados **fora do Kubernetes** (ver `validacao_local/`). |
| Cluster, rollback e medições 1/2/3 Pods | **Executados em 24/10/2026** no Minikube do autor (TAXA = 6). Tabela em `resultados.csv`, gráficos em `graficos/`. Pendente: teste com 6 réplicas (Grupo 8). |

## Estrutura

```
projeto/
├── app.py, Dockerfile, .dockerignore   aplicação e imagem (fornecidos, sem alteração)
├── carga.js                            script do k6 (fornecido, sem alteração)
├── resultados_modelo.csv               modelo da tabela (fornecido, sem alteração)
├── k8s/
│   ├── namespace.yaml                  Grupo 1 – namespace ops-lab
│   ├── deployment.yaml                 Grupo 3 – versão completa (Apêndice B)
│   ├── service.yaml                    Grupo 4 – Service ClusterIP "rotas"
│   └── job-carga.yaml                  Grupo 6 – Job "carga" com k6
├── referencia/deployment-v1.yaml       Grupo 3.1 – primeira versão (mínima)
├── scripts/
│   ├── ciclo-medicao.ps1               ciclo de medição do guia em um comando
│   └── extrair-resultados.ps1          lê resultados/ e gera resultados.csv + medianas
├── resultados/                         evidências das medições (vazia até você medir)
└── validacao_local/                    testes feitos fora do Kubernetes (não são medições)
```

## Como os nomes se ligam

| Nome | Onde aparece | Precisa bater com |
|---|---|---|
| `ops-lab` | namespace de todos os manifestos | `kubectl config set-context --current --namespace=ops-lab` |
| `rotas` (Deployment) | `kubectl rollout/scale/set image deployment/rotas` | — |
| `rotas` (contêiner) | `kubectl set image deployment/rotas rotas=rotas:1.1` | nome do contêiner no Deployment |
| `app: rotas` | labels do template | `selector` do Deployment e do Service, `kubectl logs -l app=rotas` |
| `rotas:8000` | Service | `URL` padrão do `carga.js` (`http://rotas:8000`) |
| `carga-script` | ConfigMap criado com `kubectl create configmap` | volume do Job |
| `carga` (Job) | `kubectl logs job/carga`, `-l job-name=carga` | — |
| `app: gerador-carga` | label do Pod do k6 | **diferente** de `app: rotas`, para o Service não mandar tráfego ao k6 |

## Execução passo a passo (PowerShell)

Abra o PowerShell **dentro da pasta `projeto`** com o Docker Desktop aberto.

```powershell
# Grupo 0 – ferramentas
docker version
kubectl version --client
minikube version

# Grupo 1 – cluster e contexto
minikube start -p ops-lab --driver=docker --cpus=3 --memory=3072
minikube profile ops-lab
kubectl config current-context
kubectl get nodes -o wide
kubectl apply -f k8s/namespace.yaml
kubectl config set-context --current --namespace=ops-lab
minikube addons enable metrics-server

# Grupo 2 – imagem
docker build -t rotas:1.0 .
docker run -d --rm -p 8000:8000 --name rotas-teste rotas:1.0
curl.exe http://localhost:8000/healthz
curl.exe "http://localhost:8000/api/rota?paradas=9"
docker logs rotas-teste
docker stop rotas-teste
minikube image load rotas:1.0
minikube image ls

# Grupo 3 – Deployment (duas passadas, para gerar duas revisões)
kubectl apply -f referencia/deployment-v1.yaml
kubectl rollout status deployment/rotas
kubectl get deployment,replicaset,pods
kubectl delete pod -l app=rotas
kubectl get pods -o wide
kubectl apply -f k8s/deployment.yaml
kubectl rollout status deployment/rotas
kubectl rollout history deployment/rotas
kubectl describe pod -l app=rotas          # procure QoS Class: Burstable

# Grupo 4 – Service
kubectl apply -f k8s/service.yaml
kubectl get endpointslices -l kubernetes.io/service-name=rotas
kubectl run teste --rm -it --restart=Never --image=busybox:1.36 -- wget -qO- http://rotas:8000/healthz
kubectl port-forward service/rotas 8080:8000   # 2º terminal; abra http://localhost:8080; Ctrl+C para sair

# Grupo 5 – falha e rollback
kubectl set image deployment/rotas rotas=rotas:1.1
kubectl rollout status deployment/rotas --timeout=60s     # deve falhar
kubectl get pods                                           # ErrImagePull / ImagePullBackOff
kubectl rollout undo deployment/rotas
kubectl rollout status deployment/rotas
kubectl rollout history deployment/rotas

# Grupo 6 – teste de carga (piloto)
kubectl create configmap carga-script --from-file=carga.js
mkdir resultados   # já existe no pacote; ignore o erro se aparecer
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\scripts\ciclo-medicao.ps1 -Nome piloto -Replicas 1
```

Depois do piloto, calibre `TAXA` em `k8s/job-carga.yaml` (guia, passo 6.6). Se mudar a
taxa e quiser outro piloto, use `-Nome piloto2`. **A partir daí a taxa não muda mais.**

```powershell
# Grupo 7 – série de medições (ordem do guia, passo 7.5)
.\scripts\ciclo-medicao.ps1 -Nome 3pods-a -Replicas 3
.\scripts\ciclo-medicao.ps1 -Nome 1pod-a  -Replicas 1
.\scripts\ciclo-medicao.ps1 -Nome 2pods-a -Replicas 2
.\scripts\ciclo-medicao.ps1 -Nome 2pods-b -Replicas 2
.\scripts\ciclo-medicao.ps1 -Nome 3pods-b -Replicas 3
.\scripts\ciclo-medicao.ps1 -Nome 1pod-b  -Replicas 1
.\scripts\ciclo-medicao.ps1 -Nome 1pod-c  -Replicas 1
.\scripts\ciclo-medicao.ps1 -Nome 2pods-c -Replicas 2
.\scripts\ciclo-medicao.ps1 -Nome 3pods-c -Replicas 3

.\scripts\extrair-resultados.ps1      # gera resultados.csv e resultados\medianas.csv

# Grupo 8 – limite do nó, diagnóstico e encerramento
kubectl scale deployment/rotas --replicas=6
kubectl get pods                         # parte fica Pending (Insufficient cpu)
kubectl describe node ops-lab            # Allocated resources
kubectl scale deployment/rotas --replicas=1
kubectl get events --sort-by=.lastTimestamp
kubectl delete namespace ops-lab
minikube stop
```

### O que o `ciclo-medicao.ps1` faz

Os mesmos comandos do guia (passos 6.4 e 7.1–7.4), na mesma ordem: `scale` +
`rollout status` + EndpointSlices (se usar `-Replicas`), contadores antes, `apply` do
Job, `wait`, `logs -f`, `kubectl top pods` a cada 15 s em paralelo, `logs > resultados\NOME.txt`,
status do Job e código de saída do k6, contadores depois e `delete job carga`. Ele se
recusa a rodar se o namespace padrão não for `ops-lab`, se já existir um Job `carga` ou se
`resultados\NOME.txt` já existir (para não sobrescrever evidência).

Se preferir digitar à mão (como o guia recomenda), o ciclo manual é:

```powershell
kubectl apply -f k8s/job-carga.yaml
kubectl wait --for=condition=Ready pod -l job-name=carga --timeout=180s
kubectl logs -f job/carga
kubectl logs job/carga | Out-File -Encoding utf8 resultados\NOME.txt
kubectl get job carga
kubectl delete job carga
```

> No Windows PowerShell 5.1, `kubectl logs job/carga > arquivo.txt` grava em UTF-16. Funciona
> com o `extrair-resultados.ps1`, mas `Out-File -Encoding utf8` gera um arquivo mais fácil de abrir.

## Como ler o resumo do k6

- `rotas_ok`: rotas válidas na janela medida. Sucessos por segundo = `rotas_ok / 60`
  (não use o `/s` impresso, que divide pelo tempo total com aquecimento).
- `falhas`: fração de tentativas sem rota válida (inclui 503).
- `latencia_ok p(95)`: tempo HTTP só das respostas com sucesso.
- `dropped_iterations{scenario:medicao}`: pedidos que o k6 não conseguiu iniciar. Precisa ser 0.

Metas: **p95 < 800 ms, falhas < 1%, nenhuma iteração descartada.** Meta não atingida faz o
k6 sair com código 99 e o Job aparecer como `Failed`; isso é resultado, não defeito.

## Problemas comuns

| Sinal | Causa provável |
|---|---|
| `ErrImagePull` com `rotas:1.0` | Faltou `minikube image load rotas:1.0` (ou foi para outro perfil). |
| Pod do k6 em `ContainerCreating` | ConfigMap `carga-script` não existe. |
| `no matching resources found` no `wait` | O Pod do Job ainda não foi criado; repita. |
| `metrics not available yet` | metrics-server ainda iniciando; espere 1–2 min. |
| Job `Failed` com resumo no log | Metas não atingidas (código 99). É medição válida. |
| Job sem resumo no log | Falha de execução. Não é medição; repita. |
| Volta a ter 1 réplica sozinho | Alguém rodou `kubectl apply -f k8s/deployment.yaml` (drift, guia 7.1). |

## Documentação

- https://kubernetes.io/docs/reference/kubectl/quick-reference/
- https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- https://kubernetes.io/docs/concepts/services-networking/service/
- https://kubernetes.io/docs/concepts/workloads/controllers/job/
- https://minikube.sigs.k8s.io/docs/start/
- https://grafana.com/docs/k6/latest/using-k6/scenarios/executors/constant-arrival-rate/
